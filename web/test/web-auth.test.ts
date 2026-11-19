import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, bearer, identityToken, signIn } from "./apple";

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
  return exports.default.fetch(`${ORIGIN}/api/auth/web/apple/callback`, {
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
    expect(response.headers.get("location")).toBe(`${ORIGIN}/app`);
    const raw = cookies(response).raw.join("\n");
    expect(raw).toMatch(/mg_at=[^;]+;.*Path=\/api;.*HttpOnly/);
    expect(raw).toMatch(/mg_rt=[^;]+;.*Path=\/api\/auth\/web;.*HttpOnly.*SameSite=Strict/);
    expect(raw).toMatch(/mg_web=1;.*Path=\//);
    expect(raw).not.toMatch(/mg_web=1;[^\n]*HttpOnly/);
    expect(access).not.toBe("");
    expect(refresh).not.toBe("");

    const me = await api("/me", withCookie("mg_at", access));
    expect(me.status).toBe(200);
  });

  it("returns to a same-site path, never another site", async () => {
    for (const [next, expected] of [
      ["/s/abc?x=1", "/s/abc?x=1"],
      ["//evil.example", "/app"],
      ["https://evil.example/", "/app"],
      ["/\\evil.example", "/app"],
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
      headers: { origin: ORIGIN },
    });
    expect(response.status).toBe(401);
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
