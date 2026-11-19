import { drizzle } from "drizzle-orm/d1";
import type { Context } from "hono";
import { createMiddleware } from "hono/factory";
import { apiError } from "../lib/errors";
import { isFamilyLive, verifyAccessClaims } from "./tokens";
import { accessCookie, sameOrigin } from "./web-cookies";

export type AuthEnv = { Bindings: Env; Variables: { userId: string } };
export type ViewerEnv = { Bindings: Env; Variables: { viewerId: string | null } };

const bearerToken = (header: string | undefined) =>
  /^Bearer ([^\s]+)$/i.exec(header ?? "")?.[1] ?? null;

type Credential =
  | { kind: "none" }
  | { kind: "invalid"; message: string }
  | { kind: "forbidden" }
  | { kind: "user"; userId: string };

/**
 * The caller's credential: a bearer token (the apps), else the website's access cookie.
 * A cookie on an unsafe method needs a same-origin Origin header (CSRF).
 */
// biome-ignore lint/suspicious/noExplicitAny: shared by both middleware environments.
async function credential(c: Context<any>): Promise<Credential> {
  const header = c.req.header("Authorization");
  const cookie = header === undefined ? accessCookie(c) : null;
  if (header === undefined && cookie === null) return { kind: "none" };
  if (cookie !== null && !sameOrigin(c)) return { kind: "forbidden" };
  const token = header !== undefined ? bearerToken(header) : cookie;
  const claims = token ? await verifyAccessClaims(token, c.env.JWT_SIGNING_KEY) : null;
  // The cookie only ever holds website tokens. Any token naming a sign-in (`sid`), by
  // cookie or bearer, is good only while that sign-in is live: one indexed D1 read.
  const usable =
    claims !== null &&
    (cookie === null || claims.web) &&
    (claims.sessionId === null || (await isFamilyLive(drizzle(c.env.DB), claims.sessionId)));
  if (claims && usable) return { kind: "user", userId: claims.userId };
  return {
    kind: "invalid",
    message:
      cookie !== null
        ? "The session cookie is invalid or expired."
        : "The access token is invalid or expired.",
  };
}

const crossSite = (c: Context) =>
  apiError(c, 403, "forbidden", "Cookie-authenticated changes must come from this site.");

/** Requires a bearer token or the website's session cookie, and sets `userId`. */
export const requireAuth = createMiddleware<AuthEnv>(async (c, next) => {
  const found = await credential(c);
  if (found.kind === "forbidden") return crossSite(c);
  if (found.kind !== "user") {
    return apiError(c, 401, "unauthorized", "A valid access token is required.");
  }
  c.set("userId", found.userId);
  await next();
});

/**
 * Sets `viewerId` to the signed-in user, or null for an anonymous request. A request that
 * sends an invalid or expired token or cookie gets 401 rather than an anonymous view, so a
 * client knows to refresh it.
 */
export const optionalAuth = createMiddleware<ViewerEnv>(async (c, next) => {
  const found = await credential(c);
  if (found.kind === "forbidden") return crossSite(c);
  if (found.kind === "invalid") return apiError(c, 401, "unauthorized", found.message);
  c.set("viewerId", found.kind === "user" ? found.userId : null);
  await next();
});
