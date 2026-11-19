// The server's script-readable `mg_web` cookie (src/server/auth/web-cookies.ts) holds the
// access cookie's expiry in epoch seconds. It is a hint, not a credential: it tells the
// site whether to expect a web session and when to refresh before the HttpOnly access
// cookie lapses, so a signed-in request never goes out anonymous.

/** Refresh this long before the access cookie expires. */
export const REFRESH_EARLY_S = 30;

export type SessionHint = "none" | "fresh" | "stale";

export function sessionHint(cookie: string, nowMs: number): SessionHint {
  const value = /(?:^|;\s*)mg_web=([^;]*)/.exec(cookie)?.[1];
  if (!value) return "none";
  const expiresAt = Number(value);
  // Unparseable (an older "1" hint): treat as needing a refresh, which also re-sets it.
  if (!Number.isFinite(expiresAt)) return "stale";
  return nowMs / 1000 < expiresAt - REFRESH_EARLY_S ? "fresh" : "stale";
}
