import { createRoute, z } from "@hono/zod-openapi";
import { and, eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { type PrivacyZone, privacyZones, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { reprocessUserSessions } from "../lib/postprocess";
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
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("Missing or invalid access token."),
  },
});

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
    // One statement, so concurrent requests cannot both pass the cap.
    const zone = await c.env.DB.prepare(
      `INSERT INTO privacy_zones (id, user_id, lat, lon, radius_m)
       SELECT ?, ?, ?, ?, ?
       WHERE (SELECT count(*) FROM privacy_zones WHERE user_id = ?) < ?
       RETURNING id, user_id AS userId, lat, lon, radius_m AS radiusM`,
    )
      .bind(crypto.randomUUID(), userId, body.lat, body.lon, body.radiusM, userId, MAX_ZONES)
      .first<PrivacyZone>();
    if (!zone) {
      return apiError(c, 409, "zone_limit", `At most ${MAX_ZONES} privacy zones.`);
    }
    // After the insert, so no public bounds computed without this zone survive it.
    await reprocessUserSessions(c.env, c.executionCtx, userId);
    return c.json(toBody(zone), 201);
  })
  .openapi(deleteZoneRoute, async (c) => {
    const { id } = c.req.valid("param");
    const removed = await drizzle(c.env.DB)
      .delete(privacyZones)
      .where(and(eq(privacyZones.id, id.toLowerCase()), eq(privacyZones.userId, c.var.userId)))
      .returning({ id: privacyZones.id });
    // Fewer zones only shrink what is hidden; reprocess so the public bounds grow back.
    if (removed.length > 0) await reprocessUserSessions(c.env, c.executionCtx, c.var.userId);
    return c.body(null, 204);
  });
