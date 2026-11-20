import type { Context } from "hono";
import { createMiddleware } from "hono/factory";
import type { AppEnv } from "../app";
import type { AuthEnv } from "../auth/middleware";
import { apiError, errorResponse } from "./errors";

// The bindings in wrangler.jsonc both use 60-second windows. The binding does not
// expose the time remaining, so tell callers to wait a full window.
const retryAfter = "60";

export const rateLimitedResponse = {
  ...errorResponse("Too many requests (`rate_limited`). Retry after the indicated delay."),
  headers: {
    "Retry-After": {
      description: "Seconds to wait before retrying.",
      schema: { type: "integer" as const },
    },
  },
};

function rateLimited(c: Context) {
  c.header("Retry-After", retryAfter);
  c.header("Cache-Control", "no-store");
  return apiError(c, 429, "rate_limited", "Too many requests. Try again in a minute.");
}

export const limitAuth = createMiddleware<AppEnv>(async (c, next) => {
  // Cloudflare sets this at ingress. Requests without it (like local calls) share one bucket.
  const key = c.req.header("CF-Connecting-IP")?.trim() || "unknown";
  if (!(await c.env.AUTH_RATE_LIMIT.limit({ key })).success) return rateLimited(c);
  await next();
});

/** Run after requireAuth so neither the request body nor the client chooses the key. */
export const limitSessionUpload = createMiddleware<AuthEnv>(async (c, next) => {
  const key = c.get("userId");
  if (!(await c.env.SESSION_UPLOAD_RATE_LIMIT.limit({ key })).success) return rateLimited(c);
  await next();
});
