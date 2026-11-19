import { createRoute, z } from "@hono/zod-openapi";
import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import type { Context } from "hono";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { type PrivacyZone, privacyZones, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { enqueuePostprocess } from "../lib/postprocess";
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
      "The zone is removed, but the sessions could not be queued for reprocessing " +
        "(`postprocess_unavailable`). Repeat the request.",
    ),
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("Missing or invalid access token."),
  },
});

/**
 * Statements that go in the same batch as a zone change: bump the owner's zones version
 * (public derived data is served only at the version it was computed with) and clear the
 * public data. With `insertedId`, only if that zone was inserted.
 */
function zonesChanged(db: D1Database, userId: string, insertedId?: string) {
  const guard = insertedId ? " AND EXISTS (SELECT 1 FROM privacy_zones WHERE id = ?)" : "";
  const bind = (...values: unknown[]) => (insertedId ? [...values, insertedId] : values);
  return [
    db
      .prepare(`UPDATE users SET zones_version = zones_version + 1 WHERE id = ?${guard}`)
      .bind(...bind(userId)),
    db
      .prepare(
        `UPDATE sessions SET public_min_lat = NULL, public_min_lon = NULL,
           public_max_lat = NULL, public_max_lon = NULL, public_track_started_at = NULL,
           public_track_ended_at = NULL, public_zones_version = NULL
         WHERE user_id = ?${guard}`,
      )
      .bind(...bind(userId)),
  ];
}

const requeueAfterZoneChange = (
  env: Env,
  ctx: Pick<ExecutionContext, "waitUntil">,
  userId: string,
) => enqueuePostprocess(env, ctx, [{ v: 1, kind: "user", userId }]);

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
         RETURNING id, user_id AS userId, lat, lon, radius_m AS radiusM`,
      ).bind(id, userId, body.lat, body.lon, body.radiusM, userId, MAX_ZONES),
      ...zonesChanged(c.env.DB, userId, id),
    ]);
    const zone = inserted?.results[0];
    if (!zone) {
      return apiError(c, 409, "zone_limit", `At most ${MAX_ZONES} privacy zones.`);
    }
    try {
      await requeueAfterZoneChange(c.env, c.executionCtx, userId);
    } catch (error) {
      // Undo, so the client's retry does not add the zone twice.
      console.error("Could not queue reprocessing after adding a zone.", error);
      await c.env.DB.batch([
        c.env.DB.prepare("DELETE FROM privacy_zones WHERE id = ? AND user_id = ?").bind(id, userId),
        ...zonesChanged(c.env.DB, userId),
      ]);
      return unavailable(c);
    }
    return c.json(toBody(zone), 201);
  })
  .openapi(deleteZoneRoute, async (c) => {
    const { id } = c.req.valid("param");
    const userId = c.var.userId;
    // Always bumps and requeues, even when the zone is already gone, so retrying a DELETE
    // whose requeue failed still reprocesses. Fewer zones only shrink what is hidden.
    await c.env.DB.batch([
      c.env.DB.prepare("DELETE FROM privacy_zones WHERE id = ? AND user_id = ?").bind(
        id.toLowerCase(),
        userId,
      ),
      ...zonesChanged(c.env.DB, userId),
    ]);
    try {
      await requeueAfterZoneChange(c.env, c.executionCtx, userId);
    } catch (error) {
      console.error("Could not queue reprocessing after removing a zone.", error);
      return unavailable(c);
    }
    return c.body(null, 204);
  });
