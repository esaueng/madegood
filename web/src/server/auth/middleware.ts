import { createMiddleware } from "hono/factory";
import { apiError } from "../lib/errors";
import { verifyAccessToken } from "./tokens";

export type AuthEnv = { Bindings: Env; Variables: { userId: string } };

/** Requires `Authorization: Bearer <access token>` and sets `userId`. */
export const requireAuth = createMiddleware<AuthEnv>(async (c, next) => {
  const match = /^Bearer ([^\s]+)$/i.exec(c.req.header("Authorization") ?? "");
  const userId = match?.[1] ? await verifyAccessToken(match[1], c.env.JWT_SIGNING_KEY) : null;
  if (!userId) return apiError(c, 401, "unauthorized", "A valid access token is required.");
  c.set("userId", userId);
  await next();
});
