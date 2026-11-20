import { createRoute, z } from "@hono/zod-openapi";
import { and, desc, eq, isNull, lt, or, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import type { Context } from "hono";
import { optionalAuth, requireAuth } from "../auth/middleware";
import { privacyZones, type Session, sessions, sessionTombstones, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { logFailure } from "../lib/logging";
import { enqueuePostprocess, ensureUserRequeued, publicIsCurrent } from "../lib/postprocess";
import { limitSessionUpload, rateLimitedResponse } from "../lib/rate-limit";
import { createRouter } from "../lib/router";
import { SHARED_TRACK_MAX_FIXES, shareTrack } from "../lib/session-privacy";
import {
  AfterCommit,
  accountActive,
  collectUserGarbage,
  deleteSessionRow,
  discardUpload,
  insertSession,
  replaceSessionMetadata,
  storeTrack,
  UPLOAD_REVISION_HEADER,
} from "../lib/session-upload";
import { deletePrefix, userPrefix } from "../lib/storage";
import {
  checkTrack,
  parseGzippedJson,
  readBody,
  SHARED_TRACK_MAX_INFLATED_BYTES,
  TRACK_CONTENT_TYPE,
  TRACK_MAX_BYTES,
  TRACK_SPORTS,
  TrackTooLarge,
  trackKey,
} from "../lib/track";
import { readStoredWind, WindSource } from "../lib/wind";

type SessionsEnv = {
  Bindings: Env;
  // `userId` is set by requireAuth, `viewerId` by optionalAuth; each route uses one.
  Variables: { userId: string; viewerId: string | null };
};

const security = [{ bearerAuth: [] }];
/** Routes anyone may call; a token, when sent, identifies the viewer. */
const optionalSecurity: Record<string, string[]>[] = [{ bearerAuth: [] }, {}];

const VISIBILITIES = ["private", "unlisted", "public"] as const;

/** Longest session the API accepts: 7 days. Multi-day passages are Voyages (Phase 5). */
const MAX_DURATION_S = 7 * 24 * 3600;
/** Fastest plausible speed: WaterKit's GPS filter rejects Doppler speeds above 50 m/s. */
const MAX_SPEED_MPS = 50;
const MAX_DISTANCE_M = 10_000_000;
const MAX_SUMMARY_BYTES = 64 * 1024;
/** Earliest accepted start; later starts may be at most a day ahead of the server clock. */
const MIN_STARTED_AT = Date.UTC(2000, 0, 1);
const MAX_CLOCK_SKEW_MS = 24 * 3600 * 1000;

const PAGE_DEFAULT = 20;
const PAGE_MAX = 100;

// Any RFC 4122 layout, in either case; stored lowercase like track v1's `sessionId`.
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const revisionErrorResponse = (description: string) => ({
  ...errorResponse(description),
  headers: z.object({
    [UPLOAD_REVISION_HEADER]: z.string().openapi({
      description: "The revision the server stores. A device behind it continues above it.",
    }),
  }),
});

const RevisionQuery = z.object({
  revision: z.coerce
    .number()
    .int()
    .min(0)
    .max(Number.MAX_SAFE_INTEGER)
    .optional()
    .openapi({
      type: "integer",
      format: "int64",
      description:
        "The device's upload revision for this session, increasing with each new snapshot " +
        "(0 when omitted). A PUT with a lower revision than the stored one is rejected (412).",
    }),
});

const SessionParams = z.object({
  id: z
    .string()
    .regex(UUID_PATTERN, "must be a UUID")
    .transform((s) => s.toLowerCase())
    .openapi({
      param: { name: "id", in: "path" },
      type: "string",
      format: "uuid",
      description: "The device-generated session UUID. Either case; stored lowercase.",
      example: "6f1c2a3e-8a5b-4c1d-9e2f-0a1b2c3d4e5f",
    }),
});

const isoTime = z.iso.datetime({ offset: true }).openapi({ format: "date-time" });
const seconds = z.number().min(0).max(MAX_DURATION_S);
const speed = z.number().min(0).max(MAX_SPEED_MPS);

const PutSessionRequest = z
  .object({
    sport: z.enum(TRACK_SPORTS),
    startedAt: isoTime,
    endedAt: isoTime.nullable().optional(),
    durationS: seconds.nullable().optional().openapi({ description: "Elapsed time, s." }),
    movingS: seconds.nullable().optional().openapi({ description: "Moving time, s." }),
    distanceM: z.number().min(0).max(MAX_DISTANCE_M).nullable().optional(),
    maxSpeedMps: speed.nullable().optional().openapi({ description: "Best 2 s window, m/s." }),
    avgSpeedMps: speed.nullable().optional().openapi({ description: "Distance / moving time." }),
    summary: z
      .record(z.string(), z.unknown())
      .nullable()
      .optional()
      .openapi({ description: "The track v1 summary (docs/metrics.md). At most 64 KiB." }),
    analyzerVersion: z
      .string()
      .regex(/^\d{1,4}\.\d{1,4}\.\d{1,4}$/, "must be a version such as 1.0.0")
      .nullable()
      .optional(),
  })
  .strict()
  .superRefine((body, ctx) => {
    const started = Date.parse(body.startedAt);
    if (started < MIN_STARTED_AT || started > Date.now() + MAX_CLOCK_SKEW_MS) {
      ctx.addIssue({ code: "custom", path: ["startedAt"], message: "is out of range" });
    }
    if (body.endedAt != null) {
      const ended = Date.parse(body.endedAt);
      if (ended < started || ended - started > MAX_DURATION_S * 1000) {
        ctx.addIssue({
          code: "custom",
          path: ["endedAt"],
          message: "must be after startedAt, within 7 days",
        });
      }
    }
    if (body.movingS != null && body.durationS != null && body.movingS > body.durationS) {
      ctx.addIssue({ code: "custom", path: ["movingS"], message: "exceeds durationS" });
    }
    if (body.summary != null && JSON.stringify(body.summary).length > MAX_SUMMARY_BYTES) {
      ctx.addIssue({ code: "custom", path: ["summary"], message: "is larger than 64 KiB" });
    }
  })
  .openapi("PutSessionRequest", {
    description:
      "A session's metadata and analysis summary, as the device computed them. SI units. " +
      "Every PUT replaces all of these fields; omitted ones become null. Title, notes and " +
      "visibility are not changed here (PATCH them).",
  });

const UpdateSessionRequest = z
  .object({
    title: z
      .string()
      .max(100)
      .nullable()
      .optional()
      .openapi({ description: "Blank or null clears it." }),
    notes: z
      .string()
      .max(5000)
      .nullable()
      .optional()
      .openapi({ description: "Blank or null clears it." }),
    visibility: z.enum(VISIBILITIES).optional(),
  })
  .strict()
  .openapi("UpdateSessionRequest");

const BoundsBody = z
  .object({
    south: z.number(),
    west: z.number(),
    north: z.number(),
    east: z.number().openapi({ description: "Less than `west` when the box crosses 180°." }),
  })
  .openapi("Bounds", { description: "A bounding box, degrees (WGS 84)." });

const nullableNumber = z.number().nullable();
const WindBody = z
  .object({
    source: WindSource,
    directionDeg: nullableNumber.openapi({
      description: "Mean direction the wind blows from, degrees true.",
    }),
    speedMps: nullableNumber.openapi({ description: "Mean speed at 10 m, m/s." }),
    gustMps: nullableNumber.openapi({ description: "Strongest hourly gust at 10 m, m/s." }),
    samples: z.array(
      z.object({
        t: isoTime,
        directionDeg: nullableNumber,
        speedMps: nullableNumber,
        gustMps: nullableNumber,
      }),
    ),
    fetchedAt: isoTime,
  })
  .openapi("SessionWind", {
    description:
      "Hourly model values from the hour before the start to the hour after the end. " +
      "Not an observation; not for navigation.",
  });

const SessionBody = z
  .object({
    id: z.string().openapi({ format: "uuid" }),
    sport: z.enum(TRACK_SPORTS),
    title: z.string().nullable(),
    notes: z.string().nullable(),
    visibility: z.enum(VISIBILITIES),
    startedAt: isoTime,
    endedAt: isoTime.nullable(),
    durationS: z.number().nullable(),
    movingS: z.number().nullable(),
    distanceM: z.number().nullable(),
    maxSpeedMps: z.number().nullable(),
    avgSpeedMps: z.number().nullable(),
    summary: z.record(z.string(), z.unknown()).nullable(),
    analyzerVersion: z.string().nullable(),
    hasTrack: z.boolean().openapi({ description: "Whether a track file has been uploaded." }),
    processing: z.enum(["none", "pending", "done", "too_large", "invalid"]).openapi({
      description:
        "Server post-processing of the uploaded track: `none` without a track (or for a " +
        "track uploaded before post-processing existed), `pending` until it has run, then " +
        "`done`, or `too_large`/`invalid` when no data could be derived.",
    }),
    bounds: BoundsBody.nullable().openapi({
      description:
        "The track's bounding box, null until processed. The owner gets the whole track's; " +
        "everyone else the box of what the shared track shows (privacy zones cut out).",
    }),
    trackStartedAt: isoTime.nullable().openapi({
      description:
        "First GPS fix, once processed: the owner gets the whole track's, everyone else the " +
        "first fix the shared track shows.",
    }),
    trackEndedAt: isoTime.nullable().openapi({
      description: "Last GPS fix, once processed; as for `trackStartedAt`.",
    }),
    wind: WindBody.nullable().openapi({
      description:
        "Modelled wind for the session's time and area, fetched only while " +
        "the session is public or unlisted. Null when not fetched or not available.",
    }),
    isOwner: z.boolean().openapi({ description: "Whether the caller owns the session." }),
    createdAt: isoTime,
    updatedAt: isoTime,
  })
  .openapi("Session");

const SessionList = z
  .object({
    sessions: z.array(SessionBody),
    nextCursor: z
      .string()
      .nullable()
      .openapi({ description: "Pass as `cursor` for the next page; null on the last page." }),
  })
  .openapi("SessionList");

const iso = (ms: number) => new Date(ms).toISOString();

// Summary keys anyone may see on a public or unlisted session (docs/metrics.md). The
// summary is whatever the device sent, so other viewers get only these numbers, never the
// whole object: a key holding a position would otherwise bypass privacy zones and the
// track's restrictions (review of #37). Heart rate stays with the owner.
const SHARED_SUMMARY_NUMBERS = [
  "distance",
  "movingTime",
  "elapsed",
  "averageSpeed",
  "maxSpeed2s",
  "maxSpeed10s",
  // Windsurf speed categories: speeds only, no positions.
  "best5x10s",
  "best100m",
  "best500m",
  "bestNauticalMile",
  "best1h",
  "alpha500",
] as const;
const SHARED_LAP_NUMBERS = ["start", "end", "distance", "movingTime"] as const;
const MAX_SHARED_LAPS = 1000;

const isNumber = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);

/** The owner's summary as stored; for anyone else, only the shared numbers. */
export function viewSummary(
  session: Pick<Session, "summaryJson" | "userId">,
  viewerId: string | null,
): Record<string, unknown> | null {
  if (session.summaryJson === null) return null;
  const summary: unknown = JSON.parse(session.summaryJson);
  if (session.userId === viewerId) return summary as Record<string, unknown>;
  if (typeof summary !== "object" || summary === null || Array.isArray(summary)) return null;
  const source = summary as Record<string, unknown>;

  const shared: Record<string, unknown> = {};
  for (const key of SHARED_SUMMARY_NUMBERS) {
    if (isNumber(source[key])) shared[key] = source[key];
  }
  if (Array.isArray(source.laps)) {
    shared.laps = source.laps.slice(0, MAX_SHARED_LAPS).flatMap((lap: unknown) => {
      if (typeof lap !== "object" || lap === null) return [];
      const fields = lap as Record<string, unknown>;
      const out: Record<string, unknown> = {};
      for (const key of SHARED_LAP_NUMBERS) if (isNumber(fields[key])) out[key] = fields[key];
      if (typeof fields.auto === "boolean") out.auto = fields.auto;
      return [out];
    });
  }
  return shared;
}

function processingState(session: Session): z.infer<typeof SessionBody>["processing"] {
  if (session.trackKey === null || session.trackEtag === null) return "none";
  if (session.processedEtag !== session.trackEtag || session.postprocessStatus === null) {
    return "pending";
  }
  return session.postprocessStatus;
}

function boundsOf(session: Session, owner: boolean): z.infer<typeof BoundsBody> | null {
  const box = owner
    ? [session.minLat, session.minLon, session.maxLat, session.maxLon]
    : [session.publicMinLat, session.publicMinLon, session.publicMaxLat, session.publicMaxLon];
  const [south, west, north, east] = box;
  if (south == null || west == null || north == null || east == null) return null;
  return { south, west, north, east };
}

function windOf(session: Session): z.infer<typeof WindBody> | null {
  const wind = readStoredWind(session.windJson);
  if (!wind) return null;
  return {
    source: wind.source,
    directionDeg: wind.directionDeg,
    speedMps: wind.speedMps,
    gustMps: wind.gustMps,
    samples: wind.samples.map((sample) => ({ ...sample, t: iso(sample.t) })),
    fetchedAt: iso(wind.fetchedAt),
  };
}

/**
 * `ownerZonesVersion` is the owner's users.zones_version. Others get public derived data
 * only while it was computed at that version (lib/postprocess.ts); without it, none.
 */
function toSessionBody(
  session: Session,
  viewerId: string | null,
  ownerZonesVersion?: number | null,
): z.infer<typeof SessionBody> {
  const owner = session.userId === viewerId;
  const processed = processingState(session) === "done";
  const shown = processed && (owner || publicIsCurrent(session, ownerZonesVersion));
  // The owner's times cover the whole track; others get the first and last visible fix.
  const [startedAt, endedAt] = owner
    ? [session.trackStartedAt, session.trackEndedAt]
    : [session.publicTrackStartedAt, session.publicTrackEndedAt];
  return {
    id: session.id,
    sport: session.sport,
    title: session.title,
    notes: session.notes,
    visibility: session.visibility,
    startedAt: iso(session.startedAt),
    endedAt: session.endedAt === null ? null : iso(session.endedAt),
    durationS: session.durationS,
    movingS: session.movingS,
    distanceM: session.distanceM,
    maxSpeedMps: session.maxSpeedMps,
    avgSpeedMps: session.avgSpeedMps,
    summary: viewSummary(session, viewerId),
    analyzerVersion: session.analyzerVersion,
    hasTrack: session.trackKey !== null,
    processing: processingState(session),
    bounds: shown ? boundsOf(session, owner) : null,
    trackStartedAt: shown && startedAt !== null ? iso(startedAt) : null,
    trackEndedAt: shown && endedAt !== null ? iso(endedAt) : null,
    // Wind is public data cut with the zones too: others see it only while current.
    wind: owner || publicIsCurrent(session, ownerZonesVersion) ? windOf(session) : null,
    isOwner: owner,
    createdAt: iso(session.createdAt),
    updatedAt: iso(session.updatedAt),
  };
}

// Cursors are opaque to clients: base64url JSON of the last item's [startedAt, id].
// Shared with GET /users/:handle (routes/users.ts), which pages in the same order.
const Cursor = z.tuple([z.number().int(), z.string().regex(UUID_PATTERN)]);

export function encodeCursor(session: Pick<Session, "startedAt" | "id">): string {
  return btoa(JSON.stringify([session.startedAt, session.id]))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

export function decodeCursor(cursor: string): [number, string] | null {
  try {
    const json = atob(cursor.replaceAll("-", "+").replaceAll("_", "/"));
    const parsed = Cursor.safeParse(JSON.parse(json));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

const notFound = (c: Context) => apiError(c, 404, "not_found", "No such session.");
const unknownUser = (c: Context) =>
  apiError(c, 401, "unauthorized", "The account no longer exists.");

/** Read the session and its owner's sharing state in the same D1 snapshot. */
async function findReadableSession(db: ReturnType<typeof drizzle>, id: string) {
  const [row] = await db
    .select({ session: sessions, zonesVersion: users.zonesVersion })
    .from(sessions)
    .innerJoin(users, and(eq(users.id, sessions.userId), isNull(users.deletedAt)))
    .where(and(eq(sessions.id, id), isNull(sessions.deletedAt)));
  return row;
}

/** Owners see everything; others see public and unlisted sessions. Private ones 404. */
const canView = (session: Session, viewerId: string | null) =>
  session.userId === viewerId || session.visibility !== "private";

// ---- Routes ------------------------------------------------------------------------

const listRoute = createRoute({
  method: "get",
  path: "/sessions",
  operationId: "listSessions",
  summary: "The signed-in user's sessions, newest first",
  tags: ["sessions"],
  security,
  middleware: [requireAuth] as const,
  request: {
    query: z.object({
      cursor: z.string().max(200).optional().openapi({ description: "From `nextCursor`." }),
      limit: z.coerce
        .number()
        .int()
        .min(1)
        .max(PAGE_MAX)
        .optional()
        .openapi({ type: "integer", description: `Page size, ${PAGE_DEFAULT} by default.` }),
    }),
  },
  responses: {
    200: {
      description: "A page of sessions.",
      content: { "application/json": { schema: SessionList } },
    },
    400: errorResponse("The cursor or limit is invalid."),
    401: errorResponse("Missing or invalid access token."),
  },
});

const putRoute = createRoute({
  method: "put",
  path: "/sessions/{id}",
  operationId: "putSession",
  summary: "Create or replace a session's metadata and summary",
  description:
    "Idempotent: the ID is generated on the device, so retrying an upload is safe. A new " +
    "session takes the user's default visibility. A higher `revision` than the stored one " +
    "detaches the stored track until the track for that revision is uploaded.",
  tags: ["sessions"],
  security,
  middleware: [requireAuth, limitSessionUpload] as const,
  request: {
    params: SessionParams,
    query: RevisionQuery,
    body: { required: true, content: { "application/json": { schema: PutSessionRequest } } },
  },
  responses: {
    200: {
      description: "The session was updated.",
      content: { "application/json": { schema: SessionBody } },
    },
    201: {
      description: "The session was created.",
      content: { "application/json": { schema: SessionBody } },
    },
    400: errorResponse("The ID or body is invalid."),
    401: errorResponse("Missing or invalid access token, or the account no longer exists."),
    409: errorResponse("Another account has a session with this ID (`session_id_taken`)."),
    410: errorResponse("The caller deleted this session (`session_deleted`); it stays deleted."),
    412: revisionErrorResponse("The stored revision is newer than `revision` (`stale_revision`)."),
    429: rateLimitedResponse,
  },
});

const getRoute = createRoute({
  method: "get",
  path: "/sessions/{id}",
  operationId: "getSession",
  summary: "A session",
  description:
    "For an active account, the owner can see any of their sessions. Other viewers see " +
    "only public and unlisted sessions. Once account deletion starts, its sessions are " +
    "reported as not found.",
  tags: ["sessions"],
  security: optionalSecurity,
  middleware: [optionalAuth] as const,
  request: { params: SessionParams },
  responses: {
    200: { description: "The session.", content: { "application/json": { schema: SessionBody } } },
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("An access token was sent but is invalid."),
    404: errorResponse("No such session, or the caller may not see it."),
  },
});

const putTrackRoute = createRoute({
  method: "put",
  path: "/sessions/{id}/track",
  operationId: "putSessionTrack",
  summary: "Upload a session's track file",
  description:
    `The body is the gzipped track v1 file (docs/formats.md), sent as \`${TRACK_CONTENT_TYPE}\` ` +
    `with no Content-Encoding, at most ${TRACK_MAX_BYTES} bytes. PUT the session's metadata ` +
    "first, with the same `revision`. Repeating the upload replaces the file. The server then " +
    "derives the session's bounds, track times and (for shared sessions) wind in the " +
    "background; `processing` on the session reports progress.",
  tags: ["sessions"],
  security,
  middleware: [requireAuth, limitSessionUpload] as const,
  request: {
    params: SessionParams,
    query: RevisionQuery,
    body: {
      required: true,
      content: { [TRACK_CONTENT_TYPE]: { schema: z.string().openapi({ format: "binary" }) } },
    },
  },
  responses: {
    204: { description: "The track is stored." },
    400: errorResponse("The ID is invalid, or the body is not a gzipped track (`invalid_track`)."),
    401: errorResponse("Missing or invalid access token."),
    404: errorResponse("The caller has no session with this ID; PUT its metadata first."),
    413: errorResponse(`The body is larger than ${TRACK_MAX_BYTES} bytes.`),
    410: errorResponse("The caller deleted this session (`session_deleted`)."),
    412: revisionErrorResponse(
      "`revision` is not the stored metadata revision: older (`stale_revision`) or newer " +
        "(`revision_mismatch`; PUT the metadata first), or a concurrent upload of the same " +
        "revision replaced this one's bytes (`track_replaced`; upload again).",
    ),
    415: errorResponse(`The body is not sent as ${TRACK_CONTENT_TYPE}.`),
    429: rateLimitedResponse,
    503: errorResponse(
      "The upload took too long and its object was collected (`upload_expired`; upload again), or " +
        "the track is stored but could not be queued for processing (`postprocess_unavailable`). " +
        "Repeat the upload.",
    ),
  },
});

const getTrackRoute = createRoute({
  method: "get",
  path: "/sessions/{id}/track",
  operationId: "getSessionTrack",
  summary: "Download a session's track file",
  description:
    `The gzipped track v1 file as \`${TRACK_CONTENT_TYPE}\`. Visibility works as for the ` +
    "session. The owner gets the file as uploaded. Everyone else gets a shared copy: fixes " +
    "inside the owner's privacy zones removed, a `privacyGap` event wherever the line must " +
    "break, no heart rate, only start/stop/pause/resume/lap/tack/gybe events, and the shared " +
    "summary.",
  tags: ["sessions"],
  security: optionalSecurity,
  middleware: [optionalAuth] as const,
  request: { params: SessionParams },
  responses: {
    200: {
      description: "The track file.",
      content: { [TRACK_CONTENT_TYPE]: { schema: z.string().openapi({ format: "binary" }) } },
    },
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("An access token was sent but is invalid."),
    404: errorResponse("No such session or track, or the caller may not see it."),
    422: errorResponse(
      `The track inflates to more than ${SHARED_TRACK_MAX_INFLATED_BYTES} bytes or has more ` +
        `than ${SHARED_TRACK_MAX_FIXES} fixes, too large to filter for a viewer other than ` +
        "the owner (`track_too_large`).",
    ),
  },
});

const patchRoute = createRoute({
  method: "patch",
  path: "/sessions/{id}",
  operationId: "updateSession",
  summary: "Change a session's title, notes or visibility",
  tags: ["sessions"],
  security,
  middleware: [requireAuth] as const,
  request: {
    params: SessionParams,
    body: { required: true, content: { "application/json": { schema: UpdateSessionRequest } } },
  },
  responses: {
    200: {
      description: "The updated session.",
      content: { "application/json": { schema: SessionBody } },
    },
    400: errorResponse("The ID or body is invalid."),
    401: errorResponse("Missing or invalid access token."),
    404: errorResponse("The caller has no session with this ID."),
  },
});

const deleteRoute = createRoute({
  method: "delete",
  path: "/sessions/{id}",
  operationId: "deleteSession",
  summary: "Delete a session and its track",
  description:
    "Idempotent: deleting a session the caller does not have also returns 204 and changes " +
    "nothing. A deleted session stays deleted for the caller: a later PUT for its ID returns " +
    "410, so a device still holding the recording cannot recreate it.",
  tags: ["sessions"],
  security,
  middleware: [requireAuth] as const,
  request: { params: SessionParams },
  responses: {
    204: { description: "The caller has no session with this ID any more." },
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("Missing or invalid access token."),
  },
});

export const sessionRoutes = createRouter<SessionsEnv>();

sessionRoutes.openapi(listRoute, async (c) => {
  const { cursor, limit = PAGE_DEFAULT } = c.req.valid("query");
  const after = cursor === undefined ? null : decodeCursor(cursor);
  if (cursor !== undefined && !after) return apiError(c, 400, "invalid_request", "Bad cursor.");

  const owned = eq(sessions.userId, c.var.userId);
  const live = isNull(sessions.deletedAt);
  // Newest first; the ID breaks ties between sessions that started at the same time.
  const page = after
    ? or(
        lt(sessions.startedAt, after[0]),
        and(eq(sessions.startedAt, after[0]), lt(sessions.id, after[1])),
      )
    : undefined;
  const rows = await drizzle(c.env.DB)
    .select()
    .from(sessions)
    .where(and(owned, live, page))
    .orderBy(desc(sessions.startedAt), desc(sessions.id))
    .limit(limit + 1);

  const items = rows.slice(0, limit);
  const last = items.at(-1);
  return c.json(
    {
      sessions: items.map((s) => toSessionBody(s, c.var.userId)),
      nextCursor: rows.length > limit && last ? encodeCursor(last) : null,
    },
    200,
  );
});

async function isTombstoned(db: ReturnType<typeof drizzle>, userId: string, id: string) {
  const [row] = await db
    .select({ id: sessionTombstones.id })
    .from(sessionTombstones)
    .where(and(eq(sessionTombstones.userId, userId), eq(sessionTombstones.id, id)));
  return row !== undefined;
}

const sessionDeleted = (c: Context) =>
  apiError(c, 410, "session_deleted", "This session was deleted from the account.");
/** 412 with the stored revision, so a device whose counter fell behind can move past it. */
const revisionError = (
  c: Context,
  stored: number,
  error: "stale_revision" | "revision_mismatch" = "stale_revision",
) => {
  c.header(UPLOAD_REVISION_HEADER, String(stored));
  return error === "stale_revision"
    ? apiError(c, 412, error, "A newer revision of this session is already stored.")
    : apiError(c, 412, error, "PUT the session's metadata for this revision first.");
};

sessionRoutes.openapi(putRoute, async (c) => {
  const { id } = c.req.valid("param");
  const revision = c.req.valid("query").revision ?? 0;
  const body = c.req.valid("json");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  if (await isTombstoned(db, userId, id)) return sessionDeleted(c);

  const fields = {
    sport: body.sport,
    startedAt: Date.parse(body.startedAt),
    endedAt: body.endedAt == null ? null : Date.parse(body.endedAt),
    durationS: body.durationS ?? null,
    movingS: body.movingS ?? null,
    distanceM: body.distanceM ?? null,
    maxSpeedMps: body.maxSpeedMps ?? null,
    avgSpeedMps: body.avgSpeedMps ?? null,
    summaryJson: body.summary == null ? null : JSON.stringify(body.summary),
    analyzerVersion: body.analyzerVersion ?? null,
  };
  // A DELETE that raced this PUT leaves a tombstone: remove what the PUT wrote.
  const settle = async (session: Session, status: 200 | 201) => {
    if (await isTombstoned(db, userId, id)) {
      await deleteSessionRow(db, c.env.TRACKS, id, userId);
      return sessionDeleted(c);
    }
    return c.json(toSessionBody(session, userId), status);
  };

  // Replace the caller's own session, unless it holds a newer revision. A newer revision
  // detaches the old track: its data may be what the user has since trimmed away. The
  // user_id condition means another account's session with this ID is never touched.
  const replace = () => replaceSessionMetadata(db, c.env.TRACKS, { id, userId, revision, fields });

  const replaced = await replace();
  if (replaced.kind === "stale") return revisionError(c, replaced.stored);
  if (replaced.kind === "updated") return settle(replaced.session, 200);

  // One statement: the account must be active, and it supplies the default visibility.
  const created = await insertSession(db, { id, userId, revision, fields });
  if (created) return settle(created, 201);
  if (!(await accountActive(db, userId))) return unknownUser(c);

  // The ID exists. It is either another account's, or the caller's own from a concurrent
  // first upload, which a retry of the update above handles.
  const raced = await replace();
  if (raced.kind === "stale") return revisionError(c, raced.stored);
  if (raced.kind === "updated") return settle(raced.session, 200);
  return apiError(c, 409, "session_id_taken", "This session ID is already in use.");
});

sessionRoutes.openapi(getRoute, async (c) => {
  const { id } = c.req.valid("param");
  const viewerId = c.var.viewerId;
  const row = await findReadableSession(drizzle(c.env.DB), id);
  if (!row || !canView(row.session, viewerId)) return notFound(c);
  return c.json(toSessionBody(row.session, viewerId, row.zonesVersion), 200);
});

sessionRoutes.openapi(putTrackRoute, async (c) => {
  const { id } = c.req.valid("param");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);

  const contentType = c.req.header("content-type")?.split(";")[0]?.trim().toLowerCase();
  const encoding = c.req.header("content-encoding")?.trim().toLowerCase();
  if (contentType !== TRACK_CONTENT_TYPE || (encoding && encoding !== "identity")) {
    return apiError(
      c,
      415,
      "unsupported_media_type",
      `Send the gzipped track as ${TRACK_CONTENT_TYPE}, without Content-Encoding.`,
    );
  }
  const tooLarge = () =>
    apiError(c, 413, "payload_too_large", `A track may be at most ${TRACK_MAX_BYTES} bytes.`);
  if (Number(c.req.header("content-length") ?? 0) > TRACK_MAX_BYTES) return tooLarge();

  const revision = c.req.valid("query").revision ?? 0;
  if (await isTombstoned(db, userId, id)) return sessionDeleted(c);
  const [session] = await db
    .select({ uploadRevision: sessions.uploadRevision })
    .from(sessions)
    .where(and(eq(sessions.id, id), eq(sessions.userId, userId), isNull(sessions.deletedAt)));
  if (!session) return notFound(c);
  if (session.uploadRevision !== revision) {
    return revisionError(
      c,
      session.uploadRevision,
      session.uploadRevision > revision ? "stale_revision" : "revision_mismatch",
    );
  }

  const bytes = await readBody(c.req.raw.body, TRACK_MAX_BYTES);
  if (!bytes) return tooLarge();
  const problem = await checkTrack(bytes);
  if (problem) return apiError(c, 400, "invalid_track", problem);

  // Its own object per upload attempt, attached only while the row is still at this
  // revision (and the account active), so no upload can replace or delete another's track.
  // The key is recorded for deletion before the put and unrecorded when it attaches
  // (lib/r2-garbage.ts): after any failure the object is still collected. A failure after
  // the attach committed (`AfterCommit`) never discards it; the discard itself claims the
  // record first, so it deletes nothing that attached, even after an ambiguous failure.
  const key = trackKey(userPrefix(userId), id, revision);
  const stored = await storeTrack(db, c.env.TRACKS, { id, userId, revision, key, bytes }).catch(
    async (error: unknown): Promise<never> => {
      if (!(error instanceof AfterCommit)) {
        await discardUpload(db, c.env.TRACKS, key, userId).catch(() => {});
      }
      throw error;
    },
  );
  if (stored.kind === "expired") {
    // Collected before it could attach, possibly before the put landed: delete this
    // upload's own object (best effort; recorded again if that fails).
    await discardUpload(db, c.env.TRACKS, key, userId).catch((error) =>
      logFailure("track_upload_expired_cleanup_failed", error),
    );
    return apiError(
      c,
      503,
      "upload_expired",
      "The upload took too long and was discarded; upload the track again.",
    );
  }
  const attached = stored.kind === "attached";
  if (!attached || (await isTombstoned(db, userId, id))) {
    if (attached) {
      // Deleted while the body was uploading (review of #37): the row goes again, with the
      // key it now names recorded in the same batch.
      await deleteSessionRow(db, c.env.TRACKS, id, userId);
      await collectUserGarbage(db, c.env.TRACKS, userId);
    } else {
      // Never attached: only this upload's own object goes.
      await discardUpload(db, c.env.TRACKS, key, userId);
    }
    if (!(await accountActive(db, userId))) {
      return apiError(c, 401, "unauthorized", "The account no longer exists.");
    }
    if (attached) return sessionDeleted(c);
    const [now] = await db
      .select({ uploadRevision: sessions.uploadRevision })
      .from(sessions)
      .where(and(eq(sessions.id, id), eq(sessions.userId, userId), isNull(sessions.deletedAt)));
    return now ? revisionError(c, now.uploadRevision) : notFound(c);
  }

  // Post-processing (lib/postprocess.ts) reads the whole track, checks `v` and `sessionId`,
  // derives the bounds and times, and fetches wind for shared sessions. A failed send is a
  // 503: the client repeats the upload, which is idempotent and queues it again.
  // Always for the ETag R2 holds, so the stored track is processed even when this upload
  // lost a race with another one of the same revision.
  try {
    await enqueuePostprocess(c.env, c.executionCtx, [
      { v: 1, sessionId: id, userId, revision, etag: stored.etag },
    ]);
  } catch (error) {
    logFailure("postprocess_queue_failed", error);
    return apiError(
      c,
      503,
      "postprocess_unavailable",
      "The track is stored but could not be processed; upload it again.",
    );
  }

  // A zone change whose reprocessing could not be queued earlier is retried here.
  await ensureUserRequeued(c.env, c.executionCtx, userId).catch((error) =>
    logFailure("postprocess_zone_change_queue_failed", error),
  );

  if (stored.replaced) {
    // Never report success for bytes that are not the stored ones; 412 makes the client
    // send the metadata and track again, as for a revision change.
    c.header(UPLOAD_REVISION_HEADER, String(revision));
    return apiError(
      c,
      412,
      "track_replaced",
      "Another upload of this revision replaced the track; upload it again.",
    );
  }
  c.header("ETag", stored.httpEtag);
  return c.body(null, 204);
});

sessionRoutes.openapi(getTrackRoute, async (c) => {
  const { id } = c.req.valid("param");
  const viewerId = c.var.viewerId;
  const db = drizzle(c.env.DB);
  const session = (await findReadableSession(db, id))?.session;
  if (!session || !canView(session, viewerId)) return notFound(c);

  const object = session.trackKey ? await c.env.TRACKS.get(session.trackKey) : null;
  if (!object) return apiError(c, 404, "not_found", "This session has no track.");

  if (session.userId !== viewerId) {
    // Everyone but the owner gets the shared projection: privacy zones cut out, no heart
    // rate, no marks (lib/session-privacy.ts). Read the zones first; a failure is a 500,
    // never the unfiltered track.
    const zones = await db
      .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
      .from(privacyZones)
      .where(eq(privacyZones.userId, session.userId));
    let shared: Record<string, unknown> | null = null;
    try {
      const parsed = await parseGzippedJson(object.body, SHARED_TRACK_MAX_INFLATED_BYTES);
      shared = shareTrack(parsed, zones, viewSummary(session, viewerId));
    } catch (err) {
      if (err instanceof TrackTooLarge) {
        return apiError(
          c,
          422,
          "track_too_large",
          "This track is too large to filter for anyone but its owner.",
        );
      }
      shared = null;
    }
    if (!shared) return apiError(c, 404, "not_found", "This session's track is not available.");
    const gzipped = await new Response(
      new Blob([JSON.stringify(shared)]).stream().pipeThrough(new CompressionStream("gzip")),
    ).arrayBuffer();
    // Deletion can remove the zones after this request obtained the R2 object. Recheck
    // the owner before sending a projection that may have used the emptied zone list.
    if (!(await accountActive(db, session.userId))) return notFound(c);
    return new Response(gzipped, {
      headers: {
        "content-type": TRACK_CONTENT_TYPE,
        "content-length": String(gzipped.byteLength),
        "cache-control": "private, no-cache",
      },
    });
  }

  return new Response(object.body, {
    headers: {
      "content-type": TRACK_CONTENT_TYPE,
      "content-length": String(object.size),
      etag: object.httpEtag,
      // Visibility can change at any time, so shared caches must not keep a copy.
      "cache-control": "private, no-cache",
    },
  });
});

sessionRoutes.openapi(patchRoute, async (c) => {
  const { id } = c.req.valid("param");
  const body = c.req.valid("json");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);

  const clean = (text: string | null | undefined) => text?.trim() || null;
  const changes: Partial<typeof sessions.$inferInsert> = {};
  if (body.title !== undefined) changes.title = clean(body.title);
  if (body.notes !== undefined) changes.notes = clean(body.notes);
  if (body.visibility !== undefined) changes.visibility = body.visibility;

  const mine = and(
    eq(sessions.id, id),
    eq(sessions.userId, userId),
    isNull(sessions.deletedAt),
    sql`EXISTS (SELECT 1 FROM users WHERE users.id = ${userId} AND users.deleted_at IS NULL)`,
  );
  if (Object.keys(changes).length === 0) {
    const [session] = await db.select().from(sessions).where(mine);
    return session ? c.json(toSessionBody(session, userId), 200) : notFound(c);
  }
  const [session] = await db
    .update(sessions)
    .set({ ...changes, updatedAt: Date.now() })
    .where(mine)
    .returning();
  if (!session) return notFound(c);
  // Wind is fetched only for sessions others can see; sharing one queues the lookup.
  if (session.visibility !== "private" && session.windJson === null && session.trackEtag) {
    try {
      await enqueuePostprocess(c.env, c.executionCtx, [
        { v: 1, sessionId: id, userId, revision: session.uploadRevision, etag: session.trackEtag },
      ]);
    } catch (error) {
      logFailure("wind_lookup_queue_failed", error);
    }
  }
  return c.json(toSessionBody(session, userId), 200);
});

sessionRoutes.openapi(deleteRoute, async (c) => {
  const { id } = c.req.valid("param");
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  // The row goes first, with its track key recorded and the tombstone written in the same
  // batch (lib/r2-garbage.ts), then the objects. A track upload attaches only to a live row
  // and otherwise deletes its own object, so no upload overlapping the delete leaves a track.
  // A later PUT for the ID gets 410 from the tombstone.
  await deleteSessionRow(db, c.env.TRACKS, id, userId, { tombstone: true });
  await deletePrefix(c.env.TRACKS, `${userPrefix(userId)}sessions/${id}/`);
  // Recorded keys only once no upload can still be attaching them; this session's own
  // objects are already gone with its prefix.
  await collectUserGarbage(db, c.env.TRACKS, userId);
  return c.body(null, 204);
});
