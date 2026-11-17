import { env } from "cloudflare:workers";
import { SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { api, bearer, signIn } from "./apple";

const patchMe = (token: string, body: unknown) =>
  api("/me", {
    method: "PATCH",
    headers: { ...bearer(token), "content-type": "application/json" },
    body: JSON.stringify(body),
  });

const accessToken = (options: { key?: string; sub?: string; exp?: number; typ?: string }) =>
  new SignJWT({})
    .setProtectedHeader({ alg: "HS256", typ: options.typ ?? "at+jwt" })
    .setIssuer("madegood")
    .setAudience("madegood-api")
    .setSubject(options.sub ?? "someone")
    .setIssuedAt()
    .setExpirationTime(options.exp ?? Math.floor(Date.now() / 1000) + 900)
    .sign(new TextEncoder().encode(options.key ?? env.JWT_SIGNING_KEY));

describe("GET /api/me", () => {
  it("returns the signed-in user", async () => {
    const session = await signIn({ displayName: "Navigator" });
    const response = await api("/me", { headers: bearer(session.accessToken) });
    expect(response.status).toBe(200);
    const user = (await response.json()) as Record<string, unknown>;
    expect(user).toEqual({
      id: session.user.id,
      handle: session.user.handle,
      displayName: "Navigator",
      units: "nautical",
      defaultVisibility: "private",
      createdAt: expect.stringMatching(/^\d{4}-\d\d-\d\dT/),
    });
  });
});

describe("unauthorized access", () => {
  const expectUnauthorized = async (headers: Record<string, string>) => {
    for (const method of ["GET", "PATCH", "DELETE"]) {
      const response = await api("/me", {
        method,
        headers: { ...headers, "content-type": "application/json" },
        body: method === "PATCH" ? "{}" : undefined,
      });
      expect(response.status, method).toBe(401);
      expect(response.headers.get("www-authenticate")).toMatch(/^Bearer/);
      expect(await response.json()).toMatchObject({ error: "unauthorized" });
    }
  };

  it("is refused without a token", async () => {
    await expectUnauthorized({});
    await expectUnauthorized({ authorization: "Basic abc" });
  });

  it("is refused with a token signed by another key", async () => {
    await expectUnauthorized(
      bearer(await accessToken({ key: "another-key-that-is-long-enough-0000" })),
    );
  });

  it("is refused with an expired access token", async () => {
    const session = await signIn();
    const exp = Math.floor(Date.now() / 1000) - 1;
    await expectUnauthorized(bearer(await accessToken({ sub: session.user.id, exp })));
  });

  it("is refused with a refresh token or a JWT of another type", async () => {
    const session = await signIn();
    await expectUnauthorized(bearer(session.refreshToken));
    await expectUnauthorized(bearer(await accessToken({ sub: session.user.id, typ: "JWT" })));
  });
});

describe("PATCH /api/me", () => {
  it("updates the profile and settings", async () => {
    const session = await signIn();
    const response = await patchMe(session.accessToken, {
      displayName: "  Ship's Cat ",
      handle: "Ships_Cat",
      units: "metric",
      defaultVisibility: "unlisted",
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      displayName: "Ship's Cat",
      handle: "ships_cat",
      units: "metric",
      defaultVisibility: "unlisted",
    });

    const cleared = await patchMe(session.accessToken, { displayName: null });
    expect(await cleared.json()).toMatchObject({ displayName: null, handle: "ships_cat" });

    const unchanged = await patchMe(session.accessToken, {});
    expect(unchanged.status).toBe(200);
    expect(await unchanged.json()).toMatchObject({ handle: "ships_cat", units: "metric" });
  });

  it("refuses a handle someone else has, or a reserved one", async () => {
    const owner = await signIn();
    expect((await patchMe(owner.accessToken, { handle: "first_mate" })).status).toBe(200);
    const other = await signIn();
    for (const handle of ["first_mate", "FIRST_MATE", "admin"]) {
      const response = await patchMe(other.accessToken, { handle });
      expect(response.status, handle).toBe(409);
      expect(await response.json()).toMatchObject({ error: "handle_taken" });
    }
    // Keeping your own handle is not a conflict.
    expect((await patchMe(owner.accessToken, { handle: "first_mate" })).status).toBe(200);
  });

  it("validates fields with stable error codes", async () => {
    const session = await signIn();
    for (const body of [
      { handle: "ab" },
      { handle: "has space" },
      { handle: "x".repeat(31) },
      { handle: "émile" },
      { units: "furlongs" },
      { defaultVisibility: "everyone" },
      { displayName: "x".repeat(51) },
      { unknownField: 1 },
    ]) {
      const response = await patchMe(session.accessToken, body);
      expect(response.status, JSON.stringify(body)).toBe(400);
      expect(await response.json()).toMatchObject({ error: "invalid_request" });
    }
  });
});

describe("DELETE /api/me", () => {
  it("deletes the user's rows and R2 objects, and is idempotent", async () => {
    const session = await signIn();
    const other = await signIn();
    const id = session.user.id;
    await env.DB.prepare(
      "insert into sessions (id, user_id, sport, started_at, track_key) values (?, ?, 'sup', 1, ?)",
    )
      .bind(crypto.randomUUID(), id, "legacy/track.gz")
      .run();
    await env.DB.prepare(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0, 0, 200)",
    )
      .bind(crypto.randomUUID(), id)
      .run();
    for (let i = 0; i < 3; i++) await env.TRACKS.put(`users/${id}/sessions/${i}.gz`, "track");
    await env.TRACKS.put("legacy/track.gz", "track");
    await env.TRACKS.put(`users/${other.user.id}/sessions/0.gz`, "track");

    const response = await api("/me", { method: "DELETE", headers: bearer(session.accessToken) });
    expect(response.status).toBe(204);

    for (const table of ["sessions", "refresh_tokens", "privacy_zones"]) {
      const row = await env.DB.prepare(`select count(*) as n from ${table} where user_id = ?`)
        .bind(id)
        .first<{ n: number }>();
      expect(row?.n, table).toBe(0);
    }
    const user = await env.DB.prepare("select id from users where id = ?").bind(id).first();
    expect(user).toBeNull();
    expect((await env.TRACKS.list({ prefix: `users/${id}/` })).objects).toHaveLength(0);
    expect(await env.TRACKS.head("legacy/track.gz")).toBeNull();
    // Nobody else's data is touched.
    expect(await env.TRACKS.head(`users/${other.user.id}/sessions/0.gz`)).not.toBeNull();
    expect((await api("/me", { headers: bearer(other.accessToken) })).status).toBe(200);

    // Repeating the delete succeeds; the account is gone for everything else.
    const again = await api("/me", { method: "DELETE", headers: bearer(session.accessToken) });
    expect(again.status).toBe(204);
    expect((await api("/me", { headers: bearer(session.accessToken) })).status).toBe(401);
    const refresh = await api("/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: session.refreshToken }),
    });
    expect(refresh.status).toBe(401);
  });

  it("removes more objects than one R2 list page holds", async () => {
    const session = await signIn();
    const prefix = `users/${session.user.id}/`;
    await Promise.all(Array.from({ length: 1005 }, (_, i) => env.TRACKS.put(`${prefix}${i}`, "x")));
    const response = await api("/me", { method: "DELETE", headers: bearer(session.accessToken) });
    expect(response.status).toBe(204);
    expect((await env.TRACKS.list({ prefix })).objects).toHaveLength(0);
  });
});
