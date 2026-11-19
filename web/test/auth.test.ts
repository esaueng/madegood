import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { decodeJwt } from "jose";
import { describe, expect, it } from "vitest";
import {
  consumeRefreshToken,
  endRefreshFamily,
  hashRefreshToken,
  REFRESH_REUSE_GRACE_MS,
  revokeAllRefreshTokens,
  rotateRefreshToken,
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
    const row = await env.DB.prepare(
      "select id, user_id as userId from refresh_tokens where token_hash = ?",
    )
      .bind(await hashRefreshToken(session.refreshToken))
      .first<{ id: string; userId: string }>();
    expect(row).not.toBeNull();
    if (!row) return;

    await revokeAllRefreshTokens(db, session.user.id); // B detects reuse
    expect(await consumeRefreshToken(db, row)).toBeNull(); // A's write comes after

    const live = await env.DB.prepare(
      "select count(*) as n from refresh_tokens where user_id = ? and revoked_at is null",
    )
      .bind(session.user.id)
      .first<{ n: number }>();
    expect(live?.n).toBe(0);
  });

  it("consumes a token once and stores a live successor", async () => {
    const session = await signIn();
    const db = drizzle(env.DB);
    const row = await env.DB.prepare(
      "select id, user_id as userId from refresh_tokens where token_hash = ?",
    )
      .bind(await hashRefreshToken(session.refreshToken))
      .first<{ id: string; userId: string }>();
    if (!row) throw new Error("no refresh token row");

    const successor = await consumeRefreshToken(db, row);
    expect(successor).not.toBeNull();
    // The same row cannot be consumed twice.
    expect(await consumeRefreshToken(db, row)).toBeNull();
    const stored = await env.DB.prepare(
      "select revoked_at as revokedAt from refresh_tokens where token_hash = ?",
    )
      .bind(await hashRefreshToken(successor ?? ""))
      .first<{ revokedAt: number | null }>();
    expect(stored).toEqual({ revokedAt: null });
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

describe("refresh-token families (review of #63)", () => {
  const refresh = (refreshToken: string) => postJson("/auth/refresh", { refreshToken });
  const sameAccount = async (sub: string) => [
    await signIn({ identityToken: await identityToken({ sub }) }),
    await signIn({ identityToken: await identityToken({ sub }) }),
  ];

  it("gives a token replayed within the grace window a live successor, not a reuse alarm", async () => {
    const [browser, phone] = await sameAccount("001234.grace.0001");
    if (!browser || !phone) throw new Error("sign-in failed");
    const first = await refresh(browser.refreshToken); // tab 1
    const second = await refresh(browser.refreshToken); // tab 2, same cookie
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    const a = (await first.json()) as { refreshToken: string };
    const b = (await second.json()) as { refreshToken: string };
    expect(a.refreshToken).not.toBe(b.refreshToken);
    // Both successors and the other device keep working, in the same family.
    expect((await tokenRow(a.refreshToken)).familyId).toBe(
      (await tokenRow(b.refreshToken)).familyId,
    );
    for (const token of [a.refreshToken, b.refreshToken, phone.refreshToken]) {
      expect((await refresh(token)).status).toBe(200);
    }
  });

  it("gives no grace once the family is revoked for reuse", async () => {
    const session = await signIn();
    expect((await refresh(session.refreshToken)).status).toBe(200);
    await revokeAllRefreshTokens(drizzle(env.DB), session.user.id);
    const replay = await refresh(session.refreshToken);
    expect(await replay.json()).toMatchObject({ error: "refresh_token_reused" });
  });

  it("treats a token from a signed-out family as invalid, keeping other devices", async () => {
    const [browser, phone] = await sameAccount("001234.signout.0001");
    if (!browser || !phone) throw new Error("sign-in failed");
    const rotated = (await (await refresh(browser.refreshToken)).json()) as {
      refreshToken: string;
    };
    // Sign-out presents the old token after a refresh already rotated it.
    await endRefreshFamily(drizzle(env.DB), browser.refreshToken);
    for (const token of [browser.refreshToken, rotated.refreshToken]) {
      const response = await refresh(token);
      expect(await response.json()).toMatchObject({ error: "invalid_refresh_token" });
    }
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });

  // The interleaving: a refresh reads the token, sign-out ends the family, then the
  // refresh writes. It must issue nothing and must not sign out the other devices.
  it("issues nothing when sign-out lands between a refresh's read and write", async () => {
    const [browser, phone] = await sameAccount("001234.interleave.0001");
    if (!browser || !phone) throw new Error("sign-in failed");
    const db = drizzle(env.DB);
    const row = await tokenRow(browser.refreshToken); // the refresh's read
    await endRefreshFamily(db, browser.refreshToken); // sign-out
    expect(await consumeRefreshToken(db, row)).toBeNull(); // the refresh's write
    expect(await rotateRefreshToken(db, browser.refreshToken)).toEqual({
      ok: false,
      reason: "invalid",
    });
    expect((await refresh(phone.refreshToken)).status).toBe(200);
  });
});

describe("access tokens", () => {
  it("are signed HS256 with the at+jwt type", async () => {
    const { accessToken } = await signIn();
    const header = JSON.parse(atob(accessToken.split(".")[0] ?? ""));
    expect(header).toEqual({ alg: "HS256", typ: "at+jwt" });
  });
});
