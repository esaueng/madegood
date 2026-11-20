import { createRoute, z } from "@hono/zod-openapi";
import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import type { Context } from "hono";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { type PrivacyZone, privacyZones, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { logFailure } from "../lib/logging";
import { ensureUserRequeued } from "../lib/postprocess";
import { createRouter } from "../lib/router";

const security = [{ bearerAuth: [] }];

/** Enough for home, a club and a few launch spots; bounds the per-fix zone checks. */
export const MAX_ZONES = 20;
export const MIN_RADIUS_M = 50;
export const MAX_RADIUS_M = 5000;

const ZoneBody = z
  .object({
    id: z.string().openapi({ format: "uuid" }),
    lat: z.number().openapi({ description: "Center latitude, degrees (WGS 84)." }),
    lon: z.number().openapi({ description: "Center longitude, degrees (WGS 84)." }),
    radiusM: z.number().openapi({ description: "Radius, m." }),
  })
  .openapi("PrivacyZone");

const CreateZoneRequest = z
  .object({
    lat: z.number().min(-90).max(90),
    lon: z.number().min(-180).max(180),
    radiusM: z.number().min(MIN_RADIUS_M).max(MAX_RADIUS_M),
  })
  .strict()
  .openapi("CreatePrivacyZoneRequest");

const ZoneParams = z.object({
  id: z
    .string()
    .uuid()
    .openapi({ param: { name: "id", in: "path" }, format: "uuid" }),
});

const toBody = (zone: PrivacyZone): z.infer<typeof ZoneBody> => ({
  id: zone.id,
  lat: zone.lat,
  lon: zone.lon,
  radiusM: zone.radiusM,
});

const listRoute = createRoute({
  method: "get",
  path: "/me/privacy-zones",
  summary: "The signed-in user's privacy zones",
  description:
    "Fixes inside these circles are removed from every track that someone other than the " +
    "owner downloads (GET /sessions/{id}/track).",
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  responses: {
    200: {
      description: "The zones.",
      content: {
        "application/json": {
          schema: z.object({ zones: z.array(ZoneBody) }).openapi("PrivacyZoneList"),
        },
      },
    },
    401: errorResponse("Missing or invalid access token."),
  },
});

const createZoneRoute = createRoute({
  method: "post",
  path: "/me/privacy-zones",
  summary: "Add a privacy zone",
  description: `A circle of ${MIN_RADIUS_M}–${MAX_RADIUS_M} m. At most ${MAX_ZONES} per user.`,
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: CreateZoneRequest } } },
  },
  responses: {
    201: {
      description: "The new zone.",
      content: { "application/json": { schema: ZoneBody } },
    },
    400: errorResponse("The body is invalid."),
    401: errorResponse("Missing or invalid access token, or the account no longer exists."),
    409: errorResponse(`The user already has ${MAX_ZONES} zones (\`zone_limit\`).`),
    503: errorResponse(
      "The sessions could not be queued for reprocessing (`postprocess_unavailable`); the " +
        "zone was not added. Try again.",
    ),
  },
});

const deleteZoneRoute = createRoute({
  method: "delete",
  path: "/me/privacy-zones/{id}",
  summary: "Remove a privacy zone",
  description: "Idempotent: removing a zone the caller does not have also returns 204.",
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  request: { params: ZoneParams },
  responses: {
    204: { description: "The caller has no zone with this ID any more." },
    503: errorResponse(
      "The zone is removed, but the sessions could not be queued for reprocessing yet " +
        "(`postprocess_unavailable`); the server retries on its own.",
    ),
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("Missing or invalid access token."),
  },
});

/**
 * Statements for the batch of a zone change, run only while `zoneId` exists (before a
 * delete, after an insert): bump the owner's zones version, so public derived data cut
 * with other zones stops being served, and clear that data, wind included.
 */
function zonesChanged(db: D1Database, userId: string, zoneId: string) {
  const exists = "EXISTS (SELECT 1 FROM privacy_zones WHERE id = ? AND user_id = ?)";
  return [
    db
      .prepare(
        `UPDATE users SET zones_version = zones_version + 1
         WHERE id = ? AND deleted_at IS NULL AND ${exists}`,
      )
      .bind(userId, zoneId, userId),
    db
      .prepare(
        `UPDATE sessions SET public_min_lat = NULL, public_min_lon = NULL,
           public_max_lat = NULL, public_max_lon = NULL, public_track_started_at = NULL,
           public_track_ended_at = NULL, public_zones_version = NULL, wind_json = NULL
         WHERE user_id = ? AND ${exists}`,
      )
      .bind(userId, zoneId, userId),
  ];
}

const unavailable = (c: Context) =>
  apiError(
    c,
    503,
    "postprocess_unavailable",
    "Your sessions could not be queued for reprocessing; try again.",
  );

export const privacyZoneRoutes = createRouter<AuthEnv>()
  .openapi(listRoute, async (c) => {
    const zones = await drizzle(c.env.DB)
      .select()
      .from(privacyZones)
      .where(eq(privacyZones.userId, c.var.userId))
      .orderBy(privacyZones.id);
    return c.json({ zones: zones.map(toBody) }, 200);
  })
  .openapi(createZoneRoute, async (c) => {
    const body = c.req.valid("json");
    const userId = c.var.userId;
    const db = drizzle(c.env.DB);
    const [user] = await db.select({ id: users.id }).from(users).where(eq(users.id, userId));
    if (!user) return apiError(c, 401, "unauthorized", "The account no longer exists.");
    const id = crypto.randomUUID();
    // One batch (one transaction): the insert is a single statement, so concurrent requests
    // cannot both pass the cap, and the zones version moves with it, so public data cut
    // without this zone stops being served the moment the zone exists.
    const [inserted] = await c.env.DB.batch<PrivacyZone>([
      c.env.DB.prepare(
        `INSERT INTO privacy_zones (id, user_id, lat, lon, radius_m)
         SELECT ?, ?, ?, ?, ?
         WHERE (SELECT count(*) FROM privacy_zones WHERE user_id = ?) < ?
           AND EXISTS (SELECT 1 FROM users WHERE id = ? AND deleted_at IS NULL)
         RETURNING id, user_id AS userId, lat, lon, radius_m AS radiusM`,
      ).bind(id, userId, body.lat, body.lon, body.radiusM, userId, MAX_ZONES, userId),
      ...zonesChanged(c.env.DB, userId, id),
    ]);
    const zone = inserted?.results[0];
    if (!zone) {
      return apiError(c, 409, "zone_limit", `At most ${MAX_ZONES} privacy zones.`);
    }
    try {
      await ensureUserRequeued(c.env, c.executionCtx, userId);
    } catch (error) {
      // Undo, so the client's retry does not add the zone twice. The undo is itself a zone
      // change (data cut with this zone must not outlive it); its reprocessing stays
      // marked pending (users.zones_queued_version) for the next upload, zone change or
      // scheduled sweep, so nothing stays hidden for good.
      logFailure("privacy_zone_add_queue_failed", error);
      await c.env.DB.batch([
        ...zonesChanged(c.env.DB, userId, id),
        c.env.DB.prepare("DELETE FROM privacy_zones WHERE id = ? AND user_id = ?").bind(id, userId),
      ]);
      return unavailable(c);
    }
    return c.json(toBody(zone), 201);
  })
  .openapi(deleteZoneRoute, async (c) => {
    const { id } = c.req.valid("param");
    const userId = c.var.userId;
    const zoneId = id.toLowerCase();
    // Invalidates only when the zone exists: deleting an unknown zone changes nothing.
    await c.env.DB.batch([
      ...zonesChanged(c.env.DB, userId, zoneId),
      c.env.DB.prepare("DELETE FROM privacy_zones WHERE id = ? AND user_id = ?").bind(
        zoneId,
        userId,
      ),
    ]);
    // Queues any zone change not yet queued (this one, or an earlier failed one). A failure
    // leaves the marker for the next upload, zone change or the scheduled sweep.
    try {
      await ensureUserRequeued(c.env, c.executionCtx, userId);
    } catch (error) {
      logFailure("privacy_zone_remove_queue_failed", error);
      return unavailable(c);
    }
    return c.body(null, 204);
  });
