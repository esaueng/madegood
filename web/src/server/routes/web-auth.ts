import { drizzle } from "drizzle-orm/d1";
import { Hono } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import type { AppEnv } from "../app";
import { InvalidIdentityToken, parseAudiences, verifyAppleIdentityToken } from "../auth/apple";
import {
  endRefreshFamily,
  issueTokenPair,
  rotateRefreshToken,
  signAccessToken,
} from "../auth/tokens";
import { cleanDisplayName, findOrCreateUser } from "../auth/users";
import {
  clearSessionCookies,
  refreshCookie,
  SIGN_IN_COOKIE,
  sameOrigin,
  setSessionCookies,
  WEB_AUTH_PATH,
} from "../auth/web-cookies";
import { apiError } from "../lib/errors";

// Sign in with Apple for the website, kept out of the OpenAPI document: these are browser
// redirects and cookie endpoints, not part of the API the apps use.
//
// 1. GET  /api/auth/web/apple            → 302 to Apple, with a fresh state and nonce
// 2. POST /api/auth/web/apple/callback   ← Apple's form_post; verifies the identity token,
//                                          sets the session cookies, 303 to the site
// 3. POST /api/auth/web/refresh          rotates the refresh cookie
// 4. POST /api/auth/web/signout          revokes the refresh token and clears the cookies

const APPLE_AUTHORIZE_URL = "https://appleid.apple.com/auth/authorize";
const SIGN_IN_TTL_S = 10 * 60;

const randomToken = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
};

/** A same-site path to return to after sign-in; anything else falls back to /app. */
export function safeNext(value: string | undefined | null): string {
  if (!value?.startsWith("/") || value.startsWith("//") || value.includes("\\")) {
    return "/app";
  }
  return value.length > 512 ? "/app" : value;
}

const callbackUrl = (requestUrl: string) =>
  `${new URL(requestUrl).origin}${WEB_AUTH_PATH}/apple/callback`;

/** Where the site lands after a failed sign-in; the page explains the reason. */
const failed = (requestUrl: string, reason: string) =>
  `${new URL(requestUrl).origin}/signin?error=${encodeURIComponent(reason)}`;

/** Parses the `user` JSON Apple posts on the first authorization only. */
function displayNameFrom(user: unknown): string | null {
  if (typeof user !== "string" || user === "") return null;
  try {
    const parsed = JSON.parse(user) as { name?: { firstName?: unknown; lastName?: unknown } };
    const parts = [parsed.name?.firstName, parsed.name?.lastName].filter(
      (part): part is string => typeof part === "string" && part.trim() !== "",
    );
    return cleanDisplayName(parts.join(" "));
  } catch {
    return null;
  }
}

export const webAuth = new Hono<AppEnv>();

webAuth.get("/auth/web/apple", (c) => {
  const [clientId] = parseAudiences(c.env.APPLE_WEB_CLIENT_ID);
  if (!clientId) return c.redirect(failed(c.req.url, "unavailable"), 302);
  const state = randomToken();
  const nonce = randomToken();
  const next = safeNext(c.req.query("next"));
  // Apple posts the callback cross-site, so this cookie must be SameSite=None to come back.
  setCookie(c, SIGN_IN_COOKIE, JSON.stringify({ state, nonce, next }), {
    path: `${WEB_AUTH_PATH}/apple/callback`,
    httpOnly: true,
    secure: true,
    sameSite: "None",
    maxAge: SIGN_IN_TTL_S,
  });
  const url = new URL(APPLE_AUTHORIZE_URL);
  url.search = new URLSearchParams({
    client_id: clientId,
    redirect_uri: callbackUrl(c.req.url),
    response_type: "code id_token",
    response_mode: "form_post",
    scope: "name",
    state,
    nonce,
  }).toString();
  c.header("Cache-Control", "no-store");
  return c.redirect(url.toString(), 302);
});

webAuth.post("/auth/web/apple/callback", async (c) => {
  c.header("Cache-Control", "no-store");
  const raw = getCookie(c, SIGN_IN_COOKIE);
  deleteCookie(c, SIGN_IN_COOKIE, { path: `${WEB_AUTH_PATH}/apple/callback`, secure: true });
  let pending: { state?: unknown; nonce?: unknown; next?: unknown } = {};
  try {
    pending = raw ? JSON.parse(raw) : {};
  } catch {}
  const form = await c.req.parseBody().catch(() => ({}) as Record<string, unknown>);
  if (typeof form.error === "string") {
    // The user closed or cancelled the Apple dialog.
    return c.redirect(failed(c.req.url, "cancelled"), 303);
  }
  if (
    typeof pending.state !== "string" ||
    typeof pending.nonce !== "string" ||
    form.state !== pending.state ||
    typeof form.id_token !== "string"
  ) {
    return c.redirect(failed(c.req.url, "expired"), 303);
  }
  const [clientId] = parseAudiences(c.env.APPLE_WEB_CLIENT_ID);
  if (!clientId) return c.redirect(failed(c.req.url, "unavailable"), 303);

  let sub: string;
  try {
    ({ sub } = await verifyAppleIdentityToken(form.id_token, [clientId], {
      nonce: pending.nonce,
    }));
  } catch (err) {
    if (err instanceof InvalidIdentityToken) return c.redirect(failed(c.req.url, "invalid"), 303);
    throw err;
  }
  const db = drizzle(c.env.DB);
  const { user } = await findOrCreateUser(db, sub, displayNameFrom(form.user));
  setSessionCookies(
    c,
    await issueTokenPair(db, user.id, c.env.JWT_SIGNING_KEY, { bindSession: true }),
  );
  const next = safeNext(typeof pending.next === "string" ? pending.next : null);
  return c.redirect(`${new URL(c.req.url).origin}${next}`, 303);
});

webAuth.post("/auth/web/refresh", async (c) => {
  c.header("Cache-Control", "no-store");
  if (!sameOrigin(c)) return apiError(c, 403, "forbidden", "Requests must come from this site.");
  const token = refreshCookie(c);
  if (!token) {
    // Clear the script-readable hint too, or the site would retry the refresh forever.
    clearSessionCookies(c);
    return apiError(c, 401, "invalid_refresh_token", "Not signed in.");
  }
  const db = drizzle(c.env.DB);
  const result = await rotateRefreshToken(db, token);
  if (!result.ok) {
    clearSessionCookies(c);
    return apiError(c, 401, "invalid_refresh_token", "Sign in again.");
  }
  const accessToken = await signAccessToken(result.userId, c.env.JWT_SIGNING_KEY, result.familyId);
  setSessionCookies(c, { accessToken, refreshToken: result.refreshToken });
  return c.body(null, 204);
});

webAuth.post("/auth/web/signout", async (c) => {
  c.header("Cache-Control", "no-store");
  if (!sameOrigin(c)) return apiError(c, 403, "forbidden", "Requests must come from this site.");
  const token = refreshCookie(c);
  // Ends the whole sign-in, including a successor that a concurrent refresh with the
  // same cookie may have just issued; its access token stops working too (middleware.ts).
  if (token) await endRefreshFamily(drizzle(c.env.DB), token);
  clearSessionCookies(c);
  return c.body(null, 204);
});
