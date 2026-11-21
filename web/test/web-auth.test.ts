import { env } from "cloudflare:workers";
import { decodeJwt, SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { hashRefreshToken } from "../src/server/auth/tokens";
import { signInUrl } from "../src/shared/sign-in";
import { api, bearer, deleteMe, identityToken, signIn } from "./apple";

const ORIGIN = "https://madegood.test";
const WEB_CLIENT = "app.madegood.web";

/** `name=value` pairs from a response's Set-Cookie headers, and the raw headers. */
function cookies(response: Response) {
  const raw = response.headers.getSetCookie();
  const values = new Map<string, string>();
  for (const line of raw) {
    const pair = line.split(";")[0] ?? "";
    const index = pair.indexOf("=");
    values.set(pair.slice(0, index), pair.slice(index + 1));
  }
  return { raw, values };
}

const signInCookieOf = (response: Response) =>
  (response.headers.getSetCookie()[0] ?? "").split(";")[0] ?? "";

const start = (next?: string) =>
  api(`/auth/web/apple${next === undefined ? "" : `?next=${encodeURIComponent(next)}`}`, {
    redirect: "manual",
  });

async function callback(fields: Record<string, string>, cookie?: string) {
  return api("/auth/web/apple/callback", {
    method: "POST",
    redirect: "manual",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      ...(cookie ? { cookie } : {}),
    },
    body: new URLSearchParams(fields).toString(),
  });
}

/** Runs the whole web sign-in and returns the session cookies. */
async function webSignIn(sub?: string) {
  const started = await start();
  const signInCookie = signInCookieOf(started);
  const url = new URL(started.headers.get("location") ?? "");
  const token = await identityToken({
    aud: WEB_CLIENT,
    nonce: url.searchParams.get("nonce") ?? "",
    ...(sub ? { sub } : {}),
  });
  const done = await callback(
    { state: url.searchParams.get("state") ?? "", id_token: token },
    signInCookie,
  );
  expect(done.status).toBe(303);
  const set = cookies(done).values;
  return {
    response: done,
    access: set.get("mg_at") ?? "",
    refresh: set.get("mg_rt") ?? "",
  };
}

const withCookie = (name: string, value: string, init: RequestInit = {}) => ({
  ...init,
  headers: { ...(init.headers as Record<string, string>), cookie: `${name}=${value}` },
});

describe("web sign-in with Apple", () => {
  it("redirects to Apple with the Services ID, a state and a nonce", async () => {
    const response = await start("/s/abc");
    expect(response.status).toBe(302);
    const url = new URL(response.headers.get("location") ?? "");
    expect(url.origin + url.pathname).toBe("https://appleid.apple.com/auth/authorize");
    expect(url.searchParams.get("client_id")).toBe(WEB_CLIENT);
    expect(url.searchParams.get("response_mode")).toBe("form_post");
    expect(url.searchParams.get("redirect_uri")).toBe(`${ORIGIN}/api/auth/web/apple/callback`);
    expect(url.searchParams.get("state")).toMatch(/^[\w-]{32}$/);
    expect(url.searchParams.get("nonce")).toMatch(/^[\w-]{32}$/);
    const [cookie] = cookies(response).raw;
    expect(cookie).toMatch(/^mg_signin=/);
    expect(cookie).toMatch(/HttpOnly/);
    expect(cookie).toMatch(/SameSite=None/);
    expect(cookie).toMatch(/Secure/);
  });

  it("signs in on the callback and sets HttpOnly session cookies", async () => {
    const { response, access, refresh } = await webSignIn();
    expect(response.headers.get("location")).toBe(`${ORIGIN}/sessions`);
    const raw = cookies(response).raw.join("\n");
    expect(raw).toMatch(/mg_at=[^;]+;.*Path=\/api;.*HttpOnly/);
    expect(raw).toMatch(/mg_rt=[^;]+;.*Path=\/api\/auth\/web;.*HttpOnly.*SameSite=Strict/);
    // The hint holds the access cookie's expiry, 15 minutes out, and scripts can read it.
    const hint = Number(cookies(response).values.get("mg_web"));
    expect(Math.abs(hint - (Date.now() / 1000 + 900))).toBeLessThan(5);
    expect(raw).toMatch(/mg_web=\d+;.*Path=\//);
    expect(raw).not.toMatch(/mg_web=\d+;[^\n]*HttpOnly/);
    expect(access).not.toBe("");
    expect(refresh).not.toBe("");

    const me = await api("/me", withCookie("mg_at", access));
    expect(me.status).toBe(200);
  });

  it("returns to a same-site path, never another site", async () => {
    for (const [next, expected] of [
      ["/s/abc?x=1", "/s/abc?x=1"],
      ["/u/test_skipper", "/sessions"],
      ["//evil.example", "/sessions"],
      ["https://evil.example/", "/sessions"],
      ["/\\evil.example", "/sessions"],
    ]) {
      const started = await start(next);
      const url = new URL(started.headers.get("location") ?? "");
      const token = await identityToken({
        aud: WEB_CLIENT,
        nonce: url.searchParams.get("nonce") ?? "",
      });
      const done = await callback(
        { state: url.searchParams.get("state") ?? "", id_token: token },
        signInCookieOf(started),
      );
      expect(done.headers.get("location")).toBe(`${ORIGIN}${expected}`);
    }
  });

  it("does not repeat profile paths in generated sign-in links", () => {
    expect(signInUrl("/u/test_skipper")).toBe("/api/auth/web/apple?next=%2Fsessions");
    expect(signInUrl("/U/test_skipper?view=public")).toBe("/api/auth/web/apple?next=%2Fsessions");
    expect(signInUrl("/settings")).toBe("/api/auth/web/apple?next=%2Fsettings");
  });

  it("rejects a mismatched state, nonce or audience without signing in", async () => {
    const started = await start();
    const signInCookie = signInCookieOf(started);
    const url = new URL(started.headers.get("location") ?? "");
    const state = url.searchParams.get("state") ?? "";
    const nonce = url.searchParams.get("nonce") ?? "";

    const cases: [Record<string, string>, string | undefined, string][] = [
      [
        { state: "other", id_token: await identityToken({ aud: WEB_CLIENT, nonce }) },
        signInCookie,
        "expired",
      ],
      [{ state, id_token: await identityToken({ aud: WEB_CLIENT, nonce }) }, undefined, "expired"],
      [
        { state, id_token: await identityToken({ aud: WEB_CLIENT, nonce: "other" }) },
        signInCookie,
        "invalid",
      ],
      [{ state, id_token: await identityToken({ aud: WEB_CLIENT }) }, signInCookie, "invalid"],
      // A token for the iOS app is not accepted by the website.
      [{ state, id_token: await identityToken({ nonce }) }, signInCookie, "invalid"],
      [{ state, error: "user_cancelled_authorize" }, signInCookie, "cancelled"],
    ];
    for (const [fields, cookie, reason] of cases) {
      const response = await callback(fields, cookie);
      expect(response.status).toBe(303);
      expect(response.headers.get("location")).toBe(`${ORIGIN}/signin?error=${reason}`);
      expect(cookies(response).values.has("mg_at")).toBe(false);
      expect(cookies(response).values.has("mg_rt")).toBe(false);
    }
  });
});

describe("cookie authentication", () => {
  it("needs a same-origin Origin header for changes, but not for reads", async () => {
    const { access } = await webSignIn();
    const patch = (headers: Record<string, string>) =>
      api(
        "/me",
        withCookie("mg_at", access, {
          method: "PATCH",
          headers: { "content-type": "application/json", ...headers },
          body: JSON.stringify({ units: "metric" }),
        }),
      );
    expect((await patch({})).status).toBe(403);
    expect((await patch({ origin: "https://evil.example" })).status).toBe(403);
    expect((await patch({ origin: ORIGIN })).status).toBe(200);
    expect((await api("/sessions", withCookie("mg_at", access))).status).toBe(200);
  });

  it("treats an expired or forged cookie as 401, and bearer tokens still work", async () => {
    expect((await api("/me", withCookie("mg_at", "forged"))).status).toBe(401);
    // Optional-auth routes also answer 401, so the site knows to refresh.
    expect((await api(`/sessions/${crypto.randomUUID()}`, withCookie("mg_at", "x"))).status).toBe(
      401,
    );
    const app = await signIn();
    expect((await api("/me", { headers: bearer(app.accessToken) })).status).toBe(200);
  });
});

describe("POST /api/auth/web/refresh and /signout", () => {
  const post = (path: string, refresh: string, origin: string | null = ORIGIN) =>
    api(
      path,
      withCookie("mg_rt", refresh, {
        method: "POST",
        headers: origin ? { origin } : {},
      }),
    );

  it("rotates the refresh cookie once; reuse signs out", async () => {
    const { refresh } = await webSignIn();
    expect((await post("/auth/web/refresh", refresh, null)).status).toBe(403);
    const rotated = await post("/auth/web/refresh", refresh);
    expect(rotated.status).toBe(204);
    const next = cookies(rotated).values;
    expect(next.get("mg_rt")).not.toBe(refresh);
    expect((await api("/me", withCookie("mg_at", next.get("mg_at") ?? ""))).status).toBe(200);

    // Past the 30 s grace window for replays, reuse is theft.
    await env.DB.prepare(
      "update refresh_tokens set revoked_at = revoked_at - 31000 where token_hash = ?",
    )
      .bind(await hashRefreshToken(refresh))
      .run();
    const reused = await post("/auth/web/refresh", refresh);
    expect(reused.status).toBe(401);
    expect(cookies(reused).values.get("mg_rt")).toBe("");
    // Reuse revoked the successor too.
    expect((await post("/auth/web/refresh", next.get("mg_rt") ?? "")).status).toBe(401);
  });

  it("signs out by revoking the refresh token and clearing both cookies", async () => {
    const { refresh } = await webSignIn();
    const out = await post("/auth/web/signout", refresh);
    expect(out.status).toBe(204);
    expect(cookies(out).values.get("mg_at")).toBe("");
    expect(cookies(out).values.get("mg_rt")).toBe("");
    expect(cookies(out).values.get("mg_web")).toBe("");
    expect((await post("/auth/web/refresh", refresh)).status).toBe(401);
  });

  it("refuses a refresh without a cookie", async () => {
    const response = await api("/auth/web/refresh", {
      method: "POST",
      headers: { origin: ORIGIN, cookie: "mg_web=1" },
    });
    expect(response.status).toBe(401);
    // A leftover hint is cleared, so the site stops retrying (found on the #63 preview).
    expect(cookies(response).values.get("mg_web")).toBe("");
  });
});

describe("sign-out racing a refresh (review of #63)", () => {
  const post = (path: string, refresh: string) =>
    api(path, withCookie("mg_rt", refresh, { method: "POST", headers: { origin: ORIGIN } }));

  it("ends the successor and its access cookie when the refresh lands first", async () => {
    const sub = "001234.webrace.0001";
    const { refresh: old } = await webSignIn(sub);
    const phone = await signIn({ identityToken: await identityToken({ sub }) });

    // The refresh rotates first; its response would restore these cookies.
    const rotated = cookies(await post("/auth/web/refresh", old)).values;
    // Sign-out still carries the old cookie.
    expect((await post("/auth/web/signout", old)).status).toBe(204);

    expect((await api("/me", withCookie("mg_at", rotated.get("mg_at") ?? ""))).status).toBe(401);
    const late = await post("/auth/web/refresh", rotated.get("mg_rt") ?? "");
    expect(late.status).toBe(401);
    // The phone is a different sign-in and stays signed in.
    expect((await api("/me", { headers: bearer(phone.accessToken) })).status).toBe(200);
    const phoneRefresh = await api("/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: phone.refreshToken }),
    });
    expect(phoneRefresh.status).toBe(200);
  });

  it("refuses a refresh that lands after sign-out", async () => {
    const { refresh: old, access } = await webSignIn();
    expect((await post("/auth/web/signout", old)).status).toBe(204);
    expect((await post("/auth/web/refresh", old)).status).toBe(401);
    expect((await api("/me", withCookie("mg_at", access))).status).toBe(401);
  });

  it("lets two tabs refresh with the same cookie", async () => {
    const { refresh: old } = await webSignIn();
    const [a, b] = [await post("/auth/web/refresh", old), await post("/auth/web/refresh", old)];
    expect([a.status, b.status]).toEqual([204, 204]);
    // Both tabs get the same successor: one chain, not two.
    expect(cookies(a).values.get("mg_rt")).toBe(cookies(b).values.get("mg_rt"));
    for (const response of [a, b]) {
      const access = cookies(response).values.get("mg_at") ?? "";
      expect((await api("/me", withCookie("mg_at", access))).status).toBe(200);
    }
  });
});

describe("refresh tokens per client (extra review of #63)", () => {
  const appRefresh = (refreshToken: string) =>
    api("/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    });
  const webRefresh = (refresh: string) =>
    api(
      "/auth/web/refresh",
      withCookie("mg_rt", refresh, { method: "POST", headers: { origin: ORIGIN } }),
    );

  it("never turns a website refresh cookie into an app token", async () => {
    const { refresh } = await webSignIn();
    const stolen = await appRefresh(refresh);
    expect(stolen.status).toBe(401);
    expect(await stolen.json()).toMatchObject({ error: "invalid_refresh_token" });
    // Refused without consuming it or revoking anything: the website still refreshes.
    const rotated = await webRefresh(refresh);
    expect(rotated.status).toBe(204);
    const next = cookies(rotated).values;
    // Website refreshes only mint website tokens, naming the sign-in.
    const claims = decodeJwt(next.get("mg_at") ?? "");
    expect(claims.aud).toBe("madegood-web");
    expect(typeof claims.sid).toBe("string");
    // The successor is a website token too.
    expect((await appRefresh(next.get("mg_rt") ?? "")).status).toBe(401);
    expect((await webRefresh(next.get("mg_rt") ?? "")).status).toBe(204);
  });

  it("never accepts an app refresh token as the website cookie", async () => {
    const app = await signIn();
    expect((await webRefresh(app.refreshToken)).status).toBe(401);
    expect((await appRefresh(app.refreshToken)).status).toBe(200);
  });
});

describe("website access tokens by any transport (re-check of #63)", () => {
  const key = new TextEncoder().encode(env.JWT_SIGNING_KEY);
  const forge = (claims: Record<string, unknown>, audience: string, sub: string) =>
    new SignJWT(claims)
      .setProtectedHeader({ alg: "HS256", typ: "at+jwt" })
      .setIssuer("madegood")
      .setAudience(audience)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("10m")
      .sign(key);

  it("rejects a copied website token as a bearer once its sign-in ended", async () => {
    const { access, refresh } = await webSignIn();
    expect((await api("/me", { headers: bearer(access) })).status).toBe(200);
    await api(
      "/auth/web/signout",
      withCookie("mg_rt", refresh, { method: "POST", headers: { origin: ORIGIN } }),
    );
    expect((await api("/me", { headers: bearer(access) })).status).toBe(401);
  });

  it("rejects website-audience tokens without sid, and app tokens in the cookie", async () => {
    const app = await signIn();
    const noSid = await forge({}, "madegood-web", app.user.id);
    expect((await api("/me", { headers: bearer(noSid) })).status).toBe(401);
    expect((await api("/me", withCookie("mg_at", noSid))).status).toBe(401);
    // App tokens keep working as bearers, but never as the website cookie.
    expect((await api("/me", { headers: bearer(app.accessToken) })).status).toBe(200);
    expect((await api("/me", withCookie("mg_at", app.accessToken))).status).toBe(401);
  });

  it("checks sid on an app-audience token too", async () => {
    const app = await signIn();
    const withDeadSid = await forge({ sid: crypto.randomUUID() }, "madegood-api", app.user.id);
    expect((await api("/me", { headers: bearer(withDeadSid) })).status).toBe(401);
  });
});

describe("GET /api/me/stats", () => {
  it("sums the user's own sessions, overall and per sport", async () => {
    const owner = await signIn();
    const other = await signIn();
    const put = (token: string, sport: string, distanceM: number | null) =>
      api(`/sessions/${crypto.randomUUID()}`, {
        method: "PUT",
        headers: { ...bearer(token), "content-type": "application/json" },
        body: JSON.stringify({
          sport,
          startedAt: "2000-01-01T10:00:00.000Z",
          durationS: 100,
          movingS: 90,
          distanceM,
        }),
      });
    expect((await put(owner.accessToken, "kayak", 1000)).status).toBe(201);
    expect((await put(owner.accessToken, "kayak", null)).status).toBe(201);
    expect((await put(owner.accessToken, "sailing", 500)).status).toBe(201);
    expect((await put(other.accessToken, "sailing", 9999)).status).toBe(201);

    const response = await api("/me/stats", { headers: bearer(owner.accessToken) });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      sessions: 3,
      distanceM: 1500,
      movingS: 270,
      durationS: 300,
      bySport: [
        { sport: "kayak", sessions: 2, distanceM: 1000, movingS: 180, durationS: 200 },
        { sport: "sailing", sessions: 1, distanceM: 500, movingS: 90, durationS: 100 },
      ],
    });
    expect((await api("/me/stats")).status).toBe(401);
  });
});

describe("DELETE /api/me from the website", () => {
  const remove = (access: string, origin: string | null = ORIGIN) =>
    api(
      "/me",
      withCookie("mg_at", access, {
        method: "DELETE",
        headers: { "content-type": "application/json", ...(origin ? { origin } : {}) },
        body: JSON.stringify({ userId: decodeJwt(access).sub }),
      }),
    );

  it("needs a same-origin request, deletes the account and clears the session cookies", async () => {
    const { access, refresh } = await webSignIn();
    expect((await remove(access, null)).status).toBe(403);
    expect((await remove(access, "https://evil.example")).status).toBe(403);
    expect((await api("/me", withCookie("mg_at", access))).status).toBe(200);

    const deleted = await remove(access);
    expect(deleted.status).toBe(202);
    expect(deleted.headers.get("cache-control")).toBe("no-store");
    const cleared = cookies(deleted).values;
    expect(cleared.get("mg_at")).toBe("");
    expect(cleared.get("mg_rt")).toBe("");
    expect(cleared.get("mg_web")).toBe("");
    // The sign-in went with the account: neither cookie works again.
    expect((await api("/me", withCookie("mg_at", access))).status).toBe(401);
    const refreshed = await api(
      "/auth/web/refresh",
      withCookie("mg_rt", refresh, { method: "POST", headers: { origin: ORIGIN } }),
    );
    expect(refreshed.status).toBe(401);
  });

  it("sets no cookies for an app's bearer request", async () => {
    const app = await signIn();
    const deleted = await deleteMe(app.accessToken, { finish: false });
    expect(deleted.status).toBe(202);
    expect(deleted.headers.getSetCookie()).toEqual([]);
  });
});
