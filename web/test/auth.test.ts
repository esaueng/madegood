import { env } from "cloudflare:workers";
import { decodeJwt } from "jose";
import { describe, expect, it } from "vitest";
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

describe("access tokens", () => {
  it("are signed HS256 with the at+jwt type", async () => {
    const { accessToken } = await signIn();
    const header = JSON.parse(atob(accessToken.split(".")[0] ?? ""));
    expect(header).toEqual({ alg: "HS256", typ: "at+jwt" });
  });
});
