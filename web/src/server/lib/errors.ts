import { z } from "@hono/zod-openapi";
import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";

/**
 * Stable error codes. Clients branch on `error`; `message` is for people and may change.
 * Add codes, never rename them.
 */
export const errorCodes = [
  "invalid_request",
  "unauthorized",
  "invalid_identity_token",
  "invalid_refresh_token",
  "refresh_token_reused",
  "handle_taken",
  "not_found",
  "forbidden",
  "session_id_taken",
  "sync_conflict",
  "live_capacity",
  "stale_grant",
  "unsupported_media_type",
  "payload_too_large",
  "invalid_track",
  "track_too_large",
  "zone_limit",
  "internal",
  "session_deleted",
  "stale_revision",
  "revision_mismatch",
  "postprocess_unavailable",
  "track_replaced",
  "account_mismatch",
  "account_deleting",
  "upload_expired",
  "export_in_progress",
  "export_too_large",
  "export_not_ready",
  "rate_limited",
  "sharing_disabled",
] as const;
export type ErrorCode = (typeof errorCodes)[number];

export const ErrorBody = z
  .object({
    error: z.enum(errorCodes),
    message: z.string().optional(),
  })
  .openapi("Error");

export const errorResponse = (description: string) => ({
  description,
  content: { "application/json": { schema: ErrorBody } },
});

export function apiError<S extends ContentfulStatusCode>(
  c: Context,
  status: S,
  error: ErrorCode,
  message?: string,
) {
  if (status === 401) c.header("WWW-Authenticate", 'Bearer realm="madegood"');
  return c.json(message ? { error, message } : { error }, status);
}
