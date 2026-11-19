import { createRoute, z } from "@hono/zod-openapi";
import { and, eq, gt, isNull, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import type { Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { legs, users, voyages } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { userPrefix } from "../lib/storage";
import { checkLegTrack, readBody, TRACK_CONTENT_TYPE, TRACK_MAX_BYTES } from "../lib/track";

const VoyageCollection = "/voyages";
const VoyageItem = "/voyages/{voyageId}";
const LegCollection = "/voyages/{voyageId}/legs";
const LegItem = "/voyages/{voyageId}/legs/{legId}";
const LegTrack = "/voyages/{voyageId}/legs/{legId}/track";
const PAGE_SIZE = 100;

export const deviceId = z
  .string()
  .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  .transform((value) => value.toLowerCase())
  .openapi({ type: "string", format: "uuid", description: "Device UUID, stored lowercase." });
const VoyageParams = z.object({ voyageId: deviceId });
const LegParams = VoyageParams.extend({ legId: deviceId });
const PageQuery = z.object({ cursor: deviceId.optional() });
const isoTime = z.iso.datetime({ offset: true }).openapi({ format: "date-time" });
const name = z.string().trim().max(100);
const optionalName = name.nullish();
const distanceM = z.number().nonnegative().openapi({ description: "Distance in metres." });
const orderedTimes = ({ startedAt, endedAt }: { startedAt: string; endedAt?: string | null }) =>
  endedAt == null || Date.parse(startedAt) <= Date.parse(endedAt);
const timeError = { path: ["endedAt"], message: "must be at or after startedAt" };

const PutVoyage = z
  .strictObject({
    title: name.min(1),
    boatName: optionalName,
    startedAt: isoTime,
    endedAt: isoTime.nullish(),
  })
  .refine(orderedTimes, timeError)
  .openapi("PutVoyageRequest");
const PutLeg = z
  .strictObject({
    fromName: optionalName,
    toName: optionalName,
    startedAt: isoTime,
    endedAt: isoTime,
    distanceM: distanceM.nullish(),
  })
  .refine(orderedTimes, timeError)
  .openapi("PutLegRequest");

const Voyage = z
  .object({
    id: deviceId,
    title: name,
    boatName: name.nullable(),
    startedAt: isoTime,
    endedAt: isoTime.nullable(),
  })
  .openapi("Voyage");
const Leg = z
  .object({
    id: deviceId,
    voyageId: deviceId,
    fromName: name.nullable(),
    toName: name.nullable(),
    startedAt: isoTime,
    endedAt: isoTime,
    distanceM: distanceM.nullable(),
  })
  .openapi("VoyageLeg");

const Page = z.object({ nextCursor: deviceId.nullable() });

const json = <S extends z.ZodType>(schema: S) => ({ "application/json": { schema } });
const response = <S extends z.ZodType>(description: string, schema: S) => ({
  description,
  content: json(schema),
});
const common = {
  tags: ["voyages"],
  security: [{ bearerAuth: [] }],
};
const badRequest = errorResponse("The request is invalid.");
const unauthorized = errorResponse("The access token is invalid or the account is gone.");
const missing = errorResponse("The requested private resource is unavailable.");
const conflict = errorResponse("This ID already has different content.");
const tooLarge = errorResponse("The body exceeds the upload limit.");
const jsonLimit = bodyLimit({
  maxSize: 8192,
  onError: (c) => apiError(c, 413, "payload_too_large"),
});
const trackMedia = { [TRACK_CONTENT_TYPE]: { schema: z.string().openapi({ format: "binary" }) } };

const listVoyages = createRoute({
  ...common,
  method: "get",
  path: VoyageCollection,
  operationId: "listVoyages",
  summary: "List the owner's voyages",
  request: { query: PageQuery },
  responses: {
    200: response("A page ordered by UUID.", Page.extend({ voyages: z.array(Voyage) })),
    400: badRequest,
    401: unauthorized,
  },
});
const getVoyage = createRoute({
  ...common,
  method: "get",
  path: VoyageItem,
  operationId: "getVoyage",
  summary: "Read a private voyage",
  request: { params: VoyageParams },
  responses: {
    200: response("The voyage.", Voyage),
    400: badRequest,
    401: unauthorized,
    404: missing,
  },
});
const putVoyage = createRoute({
  ...common,
  method: "put",
  path: VoyageItem,
  operationId: "putVoyage",
  summary: "Create or retry a private voyage snapshot",
  middleware: [jsonLimit],
  request: { params: VoyageParams, body: { required: true, content: json(PutVoyage) } },
  responses: {
    200: response("The same snapshot was already stored.", Voyage),
    201: response("The snapshot was stored.", Voyage),
    400: badRequest,
    401: unauthorized,
    409: conflict,
    413: tooLarge,
  },
});
const listLegs = createRoute({
  ...common,
  method: "get",
  path: LegCollection,
  operationId: "listVoyageLegs",
  summary: "List legs of a private voyage",
  request: { params: VoyageParams, query: PageQuery },
  responses: {
    200: response("A page ordered by UUID.", Page.extend({ legs: z.array(Leg) })),
    400: badRequest,
    401: unauthorized,
    404: missing,
  },
});
const getLeg = createRoute({
  ...common,
  method: "get",
  path: LegItem,
  operationId: "getVoyageLeg",
  summary: "Read a private voyage leg",
  request: { params: LegParams },
  responses: { 200: response("The leg.", Leg), 400: badRequest, 401: unauthorized, 404: missing },
});
const putLeg = createRoute({
  ...common,
  method: "put",
  path: LegItem,
  operationId: "putVoyageLeg",
  summary: "Create or retry a completed private leg snapshot",
  middleware: [jsonLimit],
  request: { params: LegParams, body: { required: true, content: json(PutLeg) } },
  responses: {
    200: response("The same snapshot was already stored.", Leg),
    201: response("The snapshot was stored.", Leg),
    400: badRequest,
    401: unauthorized,
    404: missing,
    409: conflict,
    413: tooLarge,
  },
});
const getTrack = createRoute({
  ...common,
  method: "get",
  path: LegTrack,
  operationId: "getVoyageLegTrack",
  summary: "Download a private leg track",
  request: { params: LegParams },
  responses: {
    200: { description: "The original gzip file.", content: trackMedia },
    400: badRequest,
    401: unauthorized,
    404: missing,
  },
});
const putTrack = createRoute({
  ...common,
  method: "put",
  path: LegTrack,
  operationId: "putVoyageLegTrack",
  summary: "Upload or retry a private leg track",
  description:
    "Send the track v1 gzip file with the leg UUID as sessionId. Retries must send the same bytes.",
  request: { params: LegParams, body: { required: true, content: trackMedia } },
  responses: {
    204: { description: "The track was stored or was already present with identical bytes." },
    400: badRequest,
    401: unauthorized,
    404: missing,
    409: conflict,
    413: tooLarge,
    415: errorResponse("Use application/gzip without Content-Encoding."),
  },
});

const notFound = (c: Context) => apiError(c, 404, "not_found");
const unknownUser = (c: Context) =>
  apiError(c, 401, "unauthorized", "The account no longer exists.");
const syncConflict = (c: Context) => apiError(c, 409, "sync_conflict");
const voyageOwner = (userId: string, voyageId: string) =>
  and(eq(voyages.userId, userId), eq(voyages.id, voyageId));
const legParent = (userId: string, voyageId: string) =>
  and(eq(legs.userId, userId), eq(legs.voyageId, voyageId));
const legOwner = (userId: string, voyageId: string, legId: string) =>
  and(legParent(userId, voyageId), eq(legs.id, legId));
const iso = (ms: number) => new Date(ms).toISOString();
const voyageBody = ({ userId: _, ...row }: typeof voyages.$inferSelect) => ({
  ...row,
  startedAt: iso(row.startedAt),
  endedAt: row.endedAt == null ? null : iso(row.endedAt),
});
const legBody = ({ userId: _, ...row }: typeof legs.$inferSelect) => ({
  ...row,
  startedAt: iso(row.startedAt),
  endedAt: iso(row.endedAt),
});

/** The account exists and is not being deleted (lib/account-deletion.ts). */
const hasAccount = (db: ReturnType<typeof drizzle>, userId: string) =>
  db
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.id, userId), isNull(users.deletedAt)))
    .get();
const hasLeg = (db: ReturnType<typeof drizzle>, userId: string, voyageId: string, legId: string) =>
  db
    .select({ id: legs.id })
    .from(legs)
    .where(legOwner(userId, voyageId, legId))
    .get();
const legTrackKey = (userId: string, voyageId: string, legId: string) =>
  `${userPrefix(userId)}voyages/${voyageId}/legs/${legId}/track.v1.gz`;

export const voyageRoutes = createRouter<AuthEnv>();

voyageRoutes.use("/voyages/*", async (c, next) => {
  c.header("Cache-Control", "private, no-store");
  if (c.env.VOYAGE_PRIVATE_LOCAL !== "1") return c.notFound();
  await next();
});
voyageRoutes.use("/voyages/*", requireAuth);
voyageRoutes.use("/voyages/*", async (c, next) => {
  if (!(await hasAccount(drizzle(c.env.DB), c.var.userId))) return unknownUser(c);
  await next();
});

voyageRoutes.openapi(listVoyages, async (c) => {
  const { cursor } = c.req.valid("query");
  const rows = await drizzle(c.env.DB)
    .select()
    .from(voyages)
    .where(and(eq(voyages.userId, c.var.userId), cursor ? gt(voyages.id, cursor) : undefined))
    .orderBy(voyages.id)
    .limit(PAGE_SIZE + 1);
  return c.json(
    {
      voyages: rows.slice(0, PAGE_SIZE).map(voyageBody),
      nextCursor: rows.length > PAGE_SIZE ? (rows[PAGE_SIZE - 1]?.id ?? null) : null,
    },
    200,
  );
});

voyageRoutes.openapi(getVoyage, async (c) => {
  const { voyageId } = c.req.valid("param");
  const row = await drizzle(c.env.DB)
    .select()
    .from(voyages)
    .where(voyageOwner(c.var.userId, voyageId))
    .get();
  return row ? c.json(voyageBody(row), 200) : notFound(c);
});

voyageRoutes.openapi(putVoyage, async (c) => {
  const { voyageId } = c.req.valid("param");
  const { title, boatName, startedAt, endedAt } = c.req.valid("json");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  const fields = {
    title,
    boatName: boatName || null,
    startedAt: Date.parse(startedAt),
    endedAt: endedAt == null ? null : Date.parse(endedAt),
  };

  // Read the account in the insert statement so a deleted account cannot be recreated by
  // a stale request. Batch the insert and read to classify concurrent PUTs atomically.
  const [[inserted], [row]] = await db.batch([
    db
      .insert(voyages)
      .select(
        db
          .select({
            userId: users.id,
            id: sql<string>`${voyageId}`.as("id"),
            title: sql<string>`${fields.title}`.as("title"),
            boatName: sql<string | null>`${fields.boatName}`.as("boatName"),
            startedAt: sql<number>`${fields.startedAt}`.as("startedAt"),
            endedAt: sql<number | null>`${fields.endedAt}`.as("endedAt"),
          })
          .from(users)
          // An account being deleted (lib/account-deletion.ts) gets no new rows.
          .where(and(eq(users.id, userId), isNull(users.deletedAt))),
      )
      .onConflictDoNothing()
      .returning({ id: voyages.id }),
    db.select().from(voyages).where(voyageOwner(userId, voyageId)),
  ]);
  if (!row) return unknownUser(c);
  if (
    row.title !== fields.title ||
    row.boatName !== fields.boatName ||
    row.startedAt !== fields.startedAt ||
    row.endedAt !== fields.endedAt
  )
    return syncConflict(c);
  return c.json(voyageBody(row), inserted ? 201 : 200);
});

voyageRoutes.openapi(listLegs, async (c) => {
  const { voyageId } = c.req.valid("param");
  const { cursor } = c.req.valid("query");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  const [[parent], rows] = await db.batch([
    db.select({ id: voyages.id }).from(voyages).where(voyageOwner(userId, voyageId)),
    db
      .select()
      .from(legs)
      .where(and(legParent(userId, voyageId), cursor ? gt(legs.id, cursor) : undefined))
      .orderBy(legs.id)
      .limit(PAGE_SIZE + 1),
  ]);
  if (!parent) return notFound(c);
  return c.json(
    {
      legs: rows.slice(0, PAGE_SIZE).map(legBody),
      nextCursor: rows.length > PAGE_SIZE ? (rows[PAGE_SIZE - 1]?.id ?? null) : null,
    },
    200,
  );
});

voyageRoutes.openapi(getLeg, async (c) => {
  const { voyageId, legId } = c.req.valid("param");
  const row = await drizzle(c.env.DB)
    .select()
    .from(legs)
    .where(legOwner(c.var.userId, voyageId, legId))
    .get();
  return row ? c.json(legBody(row), 200) : notFound(c);
});

voyageRoutes.openapi(putLeg, async (c) => {
  const { voyageId, legId } = c.req.valid("param");
  const { fromName, toName, startedAt, endedAt, distanceM } = c.req.valid("json");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  const parent = voyageOwner(userId, voyageId);
  const fields = {
    fromName: fromName || null,
    toName: toName || null,
    startedAt: Date.parse(startedAt),
    endedAt: Date.parse(endedAt),
    distanceM: distanceM ?? null,
  };

  const [[inserted], [voyage], [row]] = await db.batch([
    db
      .insert(legs)
      .select(
        db
          .select({
            userId: voyages.userId,
            id: sql<string>`${legId}`.as("id"),
            voyageId: voyages.id,
            fromName: sql<string | null>`${fields.fromName}`.as("fromName"),
            toName: sql<string | null>`${fields.toName}`.as("toName"),
            startedAt: sql<number>`${fields.startedAt}`.as("startedAt"),
            endedAt: sql<number>`${fields.endedAt}`.as("endedAt"),
            distanceM: sql<number | null>`${fields.distanceM}`.as("distanceM"),
          })
          .from(voyages)
          .where(
            and(
              parent,
              sql`EXISTS (SELECT 1 FROM users WHERE users.id = ${userId} AND users.deleted_at IS NULL)`,
            ),
          ),
      )
      .onConflictDoNothing()
      .returning({ id: legs.id }),
    db.select({ id: voyages.id }).from(voyages).where(parent),
    db
      .select()
      .from(legs)
      .where(and(eq(legs.userId, userId), eq(legs.id, legId))),
  ]);
  if (!voyage || !row) return notFound(c);
  if (
    row.voyageId !== voyageId ||
    row.fromName !== fields.fromName ||
    row.toName !== fields.toName ||
    row.startedAt !== fields.startedAt ||
    row.endedAt !== fields.endedAt ||
    row.distanceM !== fields.distanceM
  )
    return syncConflict(c);
  return c.json(legBody(row), inserted ? 201 : 200);
});

voyageRoutes.openapi(getTrack, async (c) => {
  const { voyageId, legId } = c.req.valid("param");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  if (!(await hasLeg(db, userId, voyageId, legId))) return notFound(c);

  const object = await c.env.TRACKS.get(legTrackKey(userId, voyageId, legId));
  if (!object) return notFound(c);
  if (!(await hasLeg(db, userId, voyageId, legId))) {
    await object.body.cancel();
    return notFound(c);
  }
  return new Response(object.body, {
    headers: {
      "content-type": TRACK_CONTENT_TYPE,
      "content-length": String(object.size),
      etag: object.httpEtag,
      "cache-control": "private, no-store",
    },
  });
});

voyageRoutes.openapi(putTrack, async (c) => {
  const { voyageId, legId } = c.req.valid("param");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  if (!(await hasLeg(db, userId, voyageId, legId))) return notFound(c);

  const contentType = c.req.header("content-type")?.split(";")[0]?.trim().toLowerCase();
  const encoding = c.req.header("content-encoding")?.trim().toLowerCase();
  if (contentType !== TRACK_CONTENT_TYPE || (encoding && encoding !== "identity")) {
    return apiError(c, 415, "unsupported_media_type");
  }
  if (Number(c.req.header("content-length") ?? 0) > TRACK_MAX_BYTES) {
    return apiError(c, 413, "payload_too_large");
  }
  const bytes = await readBody(c.req.raw.body, TRACK_MAX_BYTES);
  if (!bytes) return apiError(c, 413, "payload_too_large");
  const problem = await checkLegTrack(bytes, legId);
  if (problem) return apiError(c, 400, "invalid_track", problem);

  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const sha256 = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  if (!(await hasLeg(db, userId, voyageId, legId))) return notFound(c);

  const key = legTrackKey(userId, voyageId, legId);
  const stored = await c.env.TRACKS.put(key, bytes, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: TRACK_CONTENT_TYPE },
    customMetadata: { sha256 },
  });
  const readOwnership = async () => hasLeg(db, userId, voyageId, legId);
  if (!(await readOwnership().catch(readOwnership))) {
    // Account deletion cascades D1 rows before sweeping R2. If this PUT landed after
    // the sweep, remove the late object. This account and its storage key are never reused.
    await c.env.TRACKS.delete(key);
    return notFound(c);
  }

  const object = stored ?? (await c.env.TRACKS.head(key));
  if (!object) return apiError(c, 500, "internal");
  if (object.customMetadata?.sha256 !== sha256) return syncConflict(c);
  c.header("ETag", object.httpEtag);
  return c.body(null, 204);
});
