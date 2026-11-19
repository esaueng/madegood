import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { decodeJwt } from "jose";
import { describe, expect, it } from "vitest";
import {
  consumeRefreshToken,
  endRefreshFamily,
  hashRefreshToken,
  isFamilyLive,
  REFRESH_REUSE_GRACE_MS,
  revokeAllRefreshTokens,
  rotateRefreshToken,
  successorOf,
} from "../src/server/auth/tokens";
import { forgerKey, identityToken, jwksRequests, postJson, type SignIn, signIn } from "./apple";

describe("POST /api/auth/apple", () => {
  it("creates a user on first sign-in and returns tokens", async () => {
    const result = await signIn({ displayName: "Anne-Marie" });
    expect(result.user).toMatchObject({
      handle: "annemarie",
      displayName: "Anne-Marie",
      units: "nautical",
      defaultVisibility: "private",
    });
    expect(result.refreshToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const claims = decodeJwt(result.accessToken);
    expect(claims.sub).toBe(result.user.id);
    expect((claims.exp ?? 0) - (claims.iat ?? 0)).toBe(15 * 60);

    // Only the SHA-256 hash of the refresh token is stored.
    const row = await env.DB.prepare(
      "select token_hash, expires_at from refresh_tokens where user_id = ?",
    )
      .bind(result.user.id)
      .first<{ token_hash: string; expires_at: number }>();
    expect(row?.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row?.token_hash).not.toContain(result.refreshToken);
    expect(row?.expires_at).toBeGreaterThan(Date.now() + 59 * 24 * 3600 * 1000);
  });

  it("returns the same user for a returning Apple account", async () => {
    const sub = "001234.returning.0001";
    const first = await signIn({ identityToken: await identityToken({ sub }) });
    expect(first.user.handle).toMatch(/^sailor_\d{4}$/);
    expect(first.user.displayName).toBeNull();
    // Apple only shares the name once; a late one still fills in an empty display name.
    const second = await signIn({
      identityToken: await identityToken({ sub }),
      displayName: "Kim",
    });
    expect(second.user.id).toBe(first.user.id);
    expect(second.user.handle).toBe(first.user.handle);
    expect(second.user.displayName).toBe("Kim");
    expect(second.refreshToken).not.toBe(first.refreshToken);
  });

  it("gives a second user with the same name a different handle", async () => {
    const a = await signIn({ displayName: "Bosun" });
    const b = await signIn({ displayName: "Bosun" });
    expect(a.user.handle).toBe("bosun");
    expect(b.user.handle).toMatch(/^bosun_\d{4}$/);
  });

  it("caches Apple's keys across sign-ins", async () => {
    await signIn();
    const before = jwksRequests.length;
    await signIn();
    await signIn();
    expect(jwksRequests.length).toBe(before);
  });

  const rejects = async (token: string) => {
    const response = await postJson("/auth/apple", { identityToken: token });
    expect(response.status).toBe(401);
    expect(response.headers.get("www-authenticate")).toMatch(/^Bearer/);
    expect(await response.json()).toMatchObject({ error: "invalid_identity_token" });
  };

  it("rejects a token for another audience", async () => {
    await rejects(await identityToken({ aud: "com.example.other" }));
  });

  it("rejects an expired token", async () => {
    await rejects(await identityToken({ expiresAt: Math.floor(Date.now() / 1000) - 60 }));
  });

  it("rejects a token with a bad signature", async () => {
    await rejects(await identityToken({ key: forgerKey.privateKey }));
  });

  it("rejects a token from another issuer", async () => {
    await rejects(await identityToken({ iss: "https://example.com" }));
  });

  it("rejects garbage and missing fields with stable codes", async () => {
    await rejects("not-a-jwt");
    const missing = await postJson("/auth/apple", {});
    expect(missing.status).toBe(400);
    expect(await missing.json()).toMatchObject({ error: "invalid_request" });
    const malformed = await postJson("/auth/apple", "{");
    expect(malformed.status).toBe(400);
  });
});

const KEY = env.JWT_SIGNING_KEY;
/** Tokens from POST /auth/apple belong to the app. */
const APP = { client: "app" } as const;

const liveTokens = async (userId: string) =>
  (
    await env.DB.prepare(
      "select count(*) as n from refresh_tokens where user_id = ? and revoked_at is null",
    )
      .bind(userId)
      .first<{ n: number }>()
  )?.n;

/** Moves a rotated token's revocation `ms` into the past. */
async function ageRotation(token: string, ms: number) {
  await env.DB.prepare("update refresh_tokens set revoked_at = revoked_at - ? where token_hash = ?")
    .bind(ms, await hashRefreshToken(token))
    .run();
}

const tokenRow = async (token: string) => {
  const row = await env.DB.prepare(
    "select id, user_id as userId, family_id as familyId from refresh_tokens where token_hash = ?",
  )
    .bind(await hashRefreshToken(token))
    .first<{ id: string; userId: string; familyId: string }>();
  if (!row) throw new Error("no refresh token row");
  return row;
};

describe("POST /api/auth/refresh", () => {
  const refresh = (refreshToken: string) => postJson("/auth/refresh", { refreshToken });

  it("rotates the refresh token on every use", async () => {
    const session = await signIn();
    const response = await refresh(session.refreshToken);
    expect(response.status).toBe(200);
    const next = (await response.json()) as Omit<SignIn, "user">;
    expect(next.refreshToken).not.toBe(session.refreshToken);
    expect(decodeJwt(next.accessToken).sub).toBe(session.user.id);

    const again = await refresh(next.refreshToken);
    expect(again.status).toBe(200);
  });

  it("revokes all of the user's tokens when a used token comes back", async () => {
    const session = await signIn({
      identityToken: await identityToken({ sub: "001234.reuse.0001" }),
    });
    // A second device signed in to the same account.
    const otherDevice = await signIn({
      identityToken: await identityToken({ sub: "001234.reuse.0001" }),
    });
    const rotated = (await (await refresh(session.refreshToken)).json()) as {
      refreshToken: string;
    };
    // Past the grace window for replays (REFRESH_REUSE_GRACE_MS).
    await ageRotation(session.refreshToken, REFRESH_REUSE_GRACE_MS + 1000);

    const replay = await refresh(session.refreshToken);
    expect(replay.status).toBe(401);
    expect(await replay.json()).toMatchObject({ error: "refresh_token_reused" });

    // The legitimate successor and the other device are both signed out.
    for (const token of [rotated.refreshToken, otherDevice.refreshToken]) {
      const response = await refresh(token);
      expect(response.status).toBe(401);
      expect(await response.json()).toMatchObject({ error: "refresh_token_reused" });
    }
  });

  // Regression test from review of #36: request A reads a token, request B reuses the
  // same token and revokes everything, then A writes. A must not get a live successor.
  it("issues no successor when reuse revocation lands between read and write", async () => {
    const session = await signIn({
      identityToken: await identityToken({ sub: "001234.race.0001" }),
    });
    const db = drizzle(env.DB);
    const result = await rotateRefreshToken(db, session.refreshToken, KEY, {
      ...APP,
      hooks: { afterRead: () => revokeAllRefreshTokens(db, session.user.id) }, // B
    });
    expect(result).toEqual({ ok: false, reason: "reused" });
    expect(await liveTokens(session.user.id)).toBe(0);
  });

  it("consumes a token once and stores its derived successor", async () => {
    const session = await signIn();
    const db = drizzle(env.DB);
    const row = await tokenRow(session.refreshToken);
    const successor = await successorOf(session.refreshToken, KEY);
    expect(successor).not.toBe(session.refreshToken);
    expect(await consumeRefreshToken(db, row, successor)).toBe(true);
    // The same row cannot be consumed twice.
    expect(await consumeRefreshToken(db, row, successor)).toBe(false);
    const stored = await env.DB.prepare(
      "select revoked_at as revokedAt, family_id as familyId from refresh_tokens where token_hash = ?",
    )
      .bind(await hashRefreshToken(successor))
      .first<{ revokedAt: number | null; familyId: string }>();
    expect(stored).toEqual({ revokedAt: null, familyId: row.familyId });
  });

  it("rejects unknown and expired tokens", async () => {
    const unknown = await refresh("x".repeat(43));
    expect(unknown.status).toBe(401);
    expect(await unknown.json()).toMatchObject({ error: "invalid_refresh_token" });

    const session = await signIn();
    await env.DB.prepare("update refresh_tokens set expires_at = ? where user_id = ?")
      .bind(Date.now() - 1000, session.user.id)
      .run();
    const expired = await refresh(session.refreshToken);
    expect(expired.status).toBe(401);
    expect(await expired.json()).toMatchObject({ error: "invalid_refresh_token" });
  });
});

/** A promise the test resolves when it wants a paused request to continue. */
function gate() {
  let open: () => void = () => {};
  const opened = new Promise<void>((resolve) => {
    open = resolve;
  });
  return { open, opened };
}

/** Starts a refresh that pauses after reading its token, until `release` is called. */
function pausedRotation(token: string) {
  const reached = gate();
  const release = gate();
  const result = rotateRefreshToken(drizzle(env.DB), token, KEY, {
    ...APP,
    hooks: {
      afterRead: async () => {
        reached.open();
        await release.opened;
      },
    },
  });
  return { atRead: reached.opened, release: release.open, result };
}

describe("refresh-token families (re-check of #63)", () => {
  const refresh = (refreshToken: string) => postJson("/auth/refresh", { refreshToken });
  const newToken = async (response: Response) =>
    ((await response.json()) as { refreshToken: string }).refreshToken;
  const sameAccount = async (sub: string) => {
    const browser = await signIn({ identityToken: await identityToken({ sub }) });
    const phone = await signIn({ identityToken: await identityToken({ sub }) });
    return { browser, phone };
  };

  // Finding 1: a replay within the grace window never starts a parallel chain.
  it("gives a replay within the grace window the same successor, not a new one", async () => {
    const { browser, phone } = await sameAccount("001234.same.0001");
    const first = await refresh(browser.refreshToken);
    const second = await refresh(browser.refreshToken);
    expect([first.status, second.status]).toEqual([200, 200]);
    const successor = await newToken(first);
    expect(await newToken(second)).toBe(successor);
    expect(await liveTokens(browser.user.id)).toBe(2); // the successor and the phone's
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  it("keeps a thief who replays within the grace window on the victim's chain, then detects it", async () => {
    const { browser: victim } = await sameAccount("001234.thief.0001");
    const stolen = victim.refreshToken;
    const victimNext = await newToken(await refresh(victim.refreshToken));
    // The thief replays the stolen token within 30 s: the same successor, no new chain.
    expect(await newToken(await refresh(stolen))).toBe(victimNext);
    expect(await liveTokens(victim.user.id)).toBe(2); // the shared successor and the phone's
    // The victim moves on twice; the thief presents the shared token afterwards.
    const later = await newToken(await refresh(victimNext));
    const latest = await newToken(await refresh(later));
    const caught = await refresh(victimNext); // its successor was already used
    expect(await caught.json()).toMatchObject({ error: "refresh_token_reused" });
    expect(await (await refresh(latest)).json()).toMatchObject({ error: "refresh_token_reused" });
    expect(await liveTokens(victim.user.id)).toBe(0);
  });

  it("treats a replay as reuse once its successor was used, even within the window", async () => {
    const session = await signIn();
    const next = await newToken(await refresh(session.refreshToken));
    expect((await refresh(next)).status).toBe(200);
    const replay = await refresh(session.refreshToken);
    expect(await replay.json()).toMatchObject({ error: "refresh_token_reused" });
  });

  it("treats a replay after the grace window as reuse", async () => {
    const session = await signIn();
    expect((await refresh(session.refreshToken)).status).toBe(200);
    await ageRotation(session.refreshToken, REFRESH_REUSE_GRACE_MS + 1000);
    const replay = await refresh(session.refreshToken);
    expect(await replay.json()).toMatchObject({ error: "refresh_token_reused" });
  });

  // Finding 3: two refreshes both read the token before either consumes it.
  it("gives the loser of overlapping refreshes the winner's successor", async () => {
    const { browser, phone } = await sameAccount("001234.overlap.0001");
    const slow = pausedRotation(browser.refreshToken);
    await slow.atRead; // the slow refresh has read the unrotated token
    const fast = await rotateRefreshToken(drizzle(env.DB), browser.refreshToken, KEY, APP);
    slow.release();
    const loser = await slow.result;
    expect(fast.ok && loser.ok).toBe(true);
    if (!fast.ok || !loser.ok) return;
    expect(loser.refreshToken).toBe(fast.refreshToken);
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  it("revokes everything when the overlapping winner's successor was already used", async () => {
    const session = await signIn();
    const slow = pausedRotation(session.refreshToken);
    await slow.atRead;
    const fast = await rotateRefreshToken(drizzle(env.DB), session.refreshToken, KEY, APP);
    if (!fast.ok) throw new Error("rotation failed");
    expect((await refresh(fast.refreshToken)).status).toBe(200); // the successor moves on
    slow.release();
    expect(await slow.result).toEqual({ ok: false, reason: "reused" });
  });

  // Finding 4: sign-out landing inside a refresh is not reuse.
  it("fails a grace replay racing sign-out without revoking the other devices", async () => {
    const { browser, phone } = await sameAccount("001234.graceout.0001");
    expect((await refresh(browser.refreshToken)).status).toBe(200);
    const db = drizzle(env.DB);
    const result = await rotateRefreshToken(db, browser.refreshToken, KEY, {
      ...APP,
      hooks: { afterRead: () => endRefreshFamily(db, browser.refreshToken) },
    });
    expect(result).toEqual({ ok: false, reason: "invalid" });
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  it("fails a first refresh racing sign-out without revoking the other devices", async () => {
    const { browser, phone } = await sameAccount("001234.firstout.0001");
    const db = drizzle(env.DB);
    const result = await rotateRefreshToken(db, browser.refreshToken, KEY, {
      ...APP,
      hooks: { afterRead: () => endRefreshFamily(db, browser.refreshToken) },
    });
    expect(result).toEqual({ ok: false, reason: "invalid" });
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  it("treats tokens of a signed-out family as invalid, keeping other devices", async () => {
    const { browser, phone } = await sameAccount("001234.signout.0001");
    const rotated = await newToken(await refresh(browser.refreshToken));
    await endRefreshFamily(drizzle(env.DB), browser.refreshToken);
    for (const token of [browser.refreshToken, rotated]) {
      expect(await (await refresh(token)).json()).toMatchObject({
        error: "invalid_refresh_token",
      });
    }
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  // Finding 5: rows an older Worker wrote after the backfill have no family_id.
  it("treats a row without family_id as its own family everywhere", async () => {
    const db = drizzle(env.DB);
    const signedOut = await signIn();
    const legacy = await tokenRow(signedOut.refreshToken);
    await env.DB.prepare("update refresh_tokens set family_id = null where id = ?")
      .bind(legacy.id)
      .run();
    expect(await isFamilyLive(db, legacy.id)).toBe(true);
    await endRefreshFamily(db, signedOut.refreshToken);
    expect(await isFamilyLive(db, legacy.id)).toBe(false);
    expect((await refresh(signedOut.refreshToken)).status).toBe(401);

    // A refresh repairs the row and keeps its successor in the same family.
    const rotated = await signIn();
    const row = await tokenRow(rotated.refreshToken);
    await env.DB.prepare("update refresh_tokens set family_id = null where id = ?")
      .bind(row.id)
      .run();
    const next = await newToken(await refresh(rotated.refreshToken));
    expect((await tokenRow(rotated.refreshToken)).familyId).toBe(row.id);
    expect((await tokenRow(next)).familyId).toBe(row.id);
  });
});

describe("extra review of #63", () => {
  const refresh = (refreshToken: string) => postJson("/auth/refresh", { refreshToken });

  // Finding 2: sign-out lands after the replay decided "reuse" but before it revokes.
  it("fails a reuse whose family is signed out just before the revocation, sparing other devices", async () => {
    const sub = "001234.revokegap.0001";
    const browser = await signIn({ identityToken: await identityToken({ sub }) });
    const phone = await signIn({ identityToken: await identityToken({ sub }) });
    expect((await refresh(browser.refreshToken)).status).toBe(200);
    await ageRotation(browser.refreshToken, REFRESH_REUSE_GRACE_MS + 1000); // reuse, not grace
    const db = drizzle(env.DB);
    const result = await rotateRefreshToken(db, browser.refreshToken, KEY, {
      ...APP,
      hooks: { beforeRevoke: () => endRefreshFamily(db, browser.refreshToken) },
    });
    expect(result).toEqual({ ok: false, reason: "invalid" });
    expect(await liveTokens(browser.user.id)).toBe(1); // the phone's
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  it("still revokes everything for reuse when nothing intervenes", async () => {
    const session = await signIn();
    expect((await refresh(session.refreshToken)).status).toBe(200);
    await ageRotation(session.refreshToken, REFRESH_REUSE_GRACE_MS + 1000);
    let paused = false;
    const result = await rotateRefreshToken(drizzle(env.DB), session.refreshToken, KEY, {
      ...APP,
      hooks: {
        beforeRevoke: async () => {
          paused = true;
        },
      },
    });
    expect(paused).toBe(true);
    expect(result).toEqual({ ok: false, reason: "reused" });
    expect(await liveTokens(session.user.id)).toBe(0);
  });
});

describe("access tokens", () => {
  it("are signed HS256 with the at+jwt type", async () => {
    const { accessToken } = await signIn();
    const header = JSON.parse(atob(accessToken.split(".")[0] ?? ""));
    expect(header).toEqual({ alg: "HS256", typ: "at+jwt" });
  });
});
