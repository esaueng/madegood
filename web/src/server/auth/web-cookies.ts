import type { Context } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import { ACCESS_TOKEN_TTL_S, REFRESH_TOKEN_TTL_MS } from "./tokens";

// The website keeps its tokens in HttpOnly cookies (docs/PLAN.md §7), so page scripts never
// see them. The access cookie goes to every API path; the refresh cookie only to the web
// auth endpoints. Both are SameSite: browsers do not send them on cross-site subrequests,
// and unsafe methods also need a same-origin Origin header (sameOrigin below).

export const ACCESS_COOKIE = "mg_at";
export const REFRESH_COOKIE = "mg_rt";
/**
 * Not a credential: a script-readable hint that this browser has a web session, holding
 * the access cookie's expiry in epoch seconds. The site skips /api/me for visitors who
 * never signed in, and refreshes before the access cookie lapses.
 */
export const SIGNED_IN_COOKIE = "mg_web";
/** State and nonce of a sign-in in progress, for the Apple callback. */
export const SIGN_IN_COOKIE = "mg_signin";

export const WEB_AUTH_PATH = "/api/auth/web";

export function setSessionCookies(
  c: Context,
  tokens: { accessToken: string; refreshToken: string },
) {
  setCookie(c, ACCESS_COOKIE, tokens.accessToken, {
    path: "/api",
    httpOnly: true,
    secure: true,
    sameSite: "Lax",
    maxAge: ACCESS_TOKEN_TTL_S,
  });
  setCookie(c, REFRESH_COOKIE, tokens.refreshToken, {
    path: WEB_AUTH_PATH,
    httpOnly: true,
    secure: true,
    sameSite: "Strict",
    maxAge: Math.floor(REFRESH_TOKEN_TTL_MS / 1000),
  });
  // The hint carries the access cookie's expiry (epoch s) so the site refreshes in time.
  const accessExpiresAt = Math.floor(Date.now() / 1000) + ACCESS_TOKEN_TTL_S;
  setCookie(c, SIGNED_IN_COOKIE, String(accessExpiresAt), {
    path: "/",
    secure: true,
    sameSite: "Lax",
    maxAge: Math.floor(REFRESH_TOKEN_TTL_MS / 1000),
  });
}

export function clearSessionCookies(c: Context) {
  deleteCookie(c, ACCESS_COOKIE, { path: "/api", secure: true });
  deleteCookie(c, REFRESH_COOKIE, { path: WEB_AUTH_PATH, secure: true });
  deleteCookie(c, SIGNED_IN_COOKIE, { path: "/", secure: true });
}

export const accessCookie = (c: Context) => getCookie(c, ACCESS_COOKIE) ?? null;
export const refreshCookie = (c: Context) => getCookie(c, REFRESH_COOKIE) ?? null;

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

/**
 * Whether a cookie-authenticated request may proceed: safe methods always; others only
 * with an Origin header naming this site, so another site cannot make a signed-in
 * browser change anything (CSRF).
 */
export function sameOrigin(c: Context): boolean {
  if (SAFE_METHODS.has(c.req.method)) return true;
  const origin = c.req.header("Origin");
  return origin !== undefined && origin === new URL(c.req.url).origin;
}
