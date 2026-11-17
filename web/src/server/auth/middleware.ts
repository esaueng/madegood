import { createMiddleware } from "hono/factory";
import { apiError } from "../lib/errors";
import { verifyAccessToken } from "./tokens";

export type AuthEnv = { Bindings: Env; Variables: { userId: string } };
export type ViewerEnv = { Bindings: Env; Variables: { viewerId: string | null } };

const bearerToken = (header: string | undefined) =>
  /^Bearer ([^\s]+)$/i.exec(header ?? "")?.[1] ?? null;

/** Requires `Authorization: Bearer <access token>` and sets `userId`. */
export const requireAuth = createMiddleware<AuthEnv>(async (c, next) => {
  const token = bearerToken(c.req.header("Authorization"));
  const userId = token ? await verifyAccessToken(token, c.env.JWT_SIGNING_KEY) : null;
  if (!userId) return apiError(c, 401, "unauthorized", "A valid access token is required.");
  c.set("userId", userId);
  await next();
});

/**
 * Sets `viewerId` to the signed-in user, or null for an anonymous request. A request that
 * sends an Authorization header with an invalid or expired token gets 401 rather than an
 * anonymous view, so a client knows to refresh its token.
 */
export const optionalAuth = createMiddleware<ViewerEnv>(async (c, next) => {
  const header = c.req.header("Authorization");
  if (header === undefined) {
    c.set("viewerId", null);
    return next();
  }
  const token = bearerToken(header);
  const userId = token ? await verifyAccessToken(token, c.env.JWT_SIGNING_KEY) : null;
  if (!userId) return apiError(c, 401, "unauthorized", "The access token is invalid or expired.");
  c.set("viewerId", userId);
  await next();
});
