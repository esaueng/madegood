import { createRoute, z } from "@hono/zod-openapi";
import { and, asc, eq, gt, inArray, isNotNull, isNull, or } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { toUserBody } from "../auth/users";
import { legs, privacyZones, sessions, users, voyages } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { userPrefix } from "../lib/storage";
import { type ZipEntry, zipResponseBody } from "../lib/zip";

// GET /me/export: everything the account holds, in parts that each fit one Worker request.
//
// Without `part` the route answers a small JSON manifest. Part 1 is a ZIP of the account
// documents (profile, sessions, privacy zones, voyages), written page by page from D1 so no
// list is ever whole in memory. Parts 2… are ZIPs of at most TRACKS_PER_PART track files,
// planned from an R2 listing to stay near PART_TARGET_BYTES. Every part keeps to a budget
// of storage calls and of bytes actually streamed, so a 200 response always finishes; a
// track it cannot include (deleted, replaced beyond reach, over budget) is listed in the
// part's `errors.json` instead of being left out silently.

/** Track files per part: a few storage calls each, well inside a request's subrequest limit. */
export const TRACKS_PER_PART = 200;
/** Bytes of tracks a part is planned to hold, from the listing. */
export const PART_TARGET_BYTES = 256 * 1024 * 1024;
/** Bytes of tracks a part may stream: twice the plan, for tracks that grew since. */
export const PART_MAX_BYTES = 512 * 1024 * 1024;
/** R2 and D1 calls a part may make after its preflight (listing and planning). */
export const PART_MAX_STORAGE_CALLS = 3 * TRACKS_PER_PART + 50;
/** Track files an account may export (100 track parts). */
export const EXPORT_MAX_TRACKS = 20_000;
/** D1 rows read per query while writing the JSON documents. */
export const PAGE_ROWS = 200;
/** Voyages per page: their legs are read with one IN (…) query, under D1's 100 parameters. */
const VOYAGE_PAGE = 50;

const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());

const parseJson = (text: string | null): unknown => {
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};

const encoder = new TextEncoder();
const json = (value: unknown) => encoder.encode(`${JSON.stringify(value, null, 2)}\n`);

type Db = ReturnType<typeof drizzle>;

/** A JSON array written page by page: `[`, then each page's items, then `]`. */
export async function* jsonArray<T>(pages: AsyncIterable<T[]>): AsyncGenerator<Uint8Array> {
  let first = true;
  yield encoder.encode("[");
  for await (const page of pages) {
    if (page.length === 0) continue;
    const items = page.map((item) => JSON.stringify(item, null, 2).replaceAll("\n", "\n  "));
    yield encoder.encode(`${first ? "\n  " : ",\n  "}${items.join(",\n  ")}`);
    first = false;
  }
  yield encoder.encode(first ? "]\n" : "\n]\n");
}

function toStream(chunks: AsyncGenerator<Uint8Array>): ReadableStream<Uint8Array> {
  return new ReadableStream({
    async pull(controller) {
      const { done, value } = await chunks.next();
      if (done) controller.close();
      else controller.enqueue(value);
    },
    async cancel() {
      await chunks.return(undefined);
    },
  });
}

const sessionTrackName = (id: string) => `tracks/sessions/${id}.track.v1.gz`;
const legTrackName = (voyageId: string, legId: string) =>
  `tracks/voyages/${voyageId}/${legId}.track.v1.gz`;
const legTrackKey = (userId: string, voyageId: string, legId: string) =>
  `${userPrefix(userId)}voyages/${voyageId}/legs/${legId}/track.v1.gz`;

type SessionRow = typeof sessions.$inferSelect;

const sessionDocument = (s: SessionRow) => ({
  id: s.id,
  sport: s.sport,
  title: s.title,
  notes: s.notes,
  visibility: s.visibility,
  startedAt: iso(s.startedAt),
  endedAt: iso(s.endedAt),
  durationS: s.durationS,
  movingS: s.movingS,
  distanceM: s.distanceM,
  maxSpeedMps: s.maxSpeedMps,
  avgSpeedMps: s.avgSpeedMps,
  bounds:
    s.minLat === null
      ? null
      : { minLat: s.minLat, minLon: s.minLon, maxLat: s.maxLat, maxLon: s.maxLon },
  startGeohash: s.startGeohash,
  summary: parseJson(s.summaryJson),
  wind: parseJson(s.windJson),
  analyzerVersion: s.analyzerVersion,
  uploadRevision: s.uploadRevision,
  track: s.trackKey ? sessionTrackName(s.id) : null,
  createdAt: iso(s.createdAt),
  updatedAt: iso(s.updatedAt),
});

/** Session documents in (startedAt, id) order, `pageRows` rows per D1 query (keyset paging). */
export async function* sessionPages(
  db: Db,
  userId: string,
  pageRows = PAGE_ROWS,
): AsyncGenerator<ReturnType<typeof sessionDocument>[]> {
  let after: { startedAt: number; id: string } | null = null;
  for (;;) {
    const page: SessionRow[] = await db
      .select()
      .from(sessions)
      .where(
        and(
          eq(sessions.userId, userId),
          isNull(sessions.deletedAt),
          after
            ? or(
                gt(sessions.startedAt, after.startedAt),
                and(eq(sessions.startedAt, after.startedAt), gt(sessions.id, after.id)),
              )
            : undefined,
        ),
      )
      .orderBy(asc(sessions.startedAt), asc(sessions.id))
      .limit(pageRows);
    if (page.length === 0) return;
    yield page.map(sessionDocument);
    if (page.length < pageRows) return;
    const last = page[page.length - 1] as SessionRow;
    after = { startedAt: last.startedAt, id: last.id };
  }
}

async function* voyagePages(db: Db, userId: string): AsyncGenerator<unknown[]> {
  let after: string | null = null;
  for (;;) {
    const page = await db
      .select()
      .from(voyages)
      .where(and(eq(voyages.userId, userId), after ? gt(voyages.id, after) : undefined))
      .orderBy(asc(voyages.id))
      .limit(VOYAGE_PAGE);
    if (page.length === 0) return;
    const legRows = await db
      .select()
      .from(legs)
      .where(
        and(
          eq(legs.userId, userId),
          inArray(
            legs.voyageId,
            page.map((v) => v.id),
          ),
        ),
      )
      .orderBy(asc(legs.startedAt), asc(legs.id));
    yield page.map((v) => ({
      id: v.id,
      title: v.title,
      boatName: v.boatName,
      startedAt: iso(v.startedAt),
      endedAt: iso(v.endedAt),
      legs: legRows
        .filter((l) => l.voyageId === v.id)
        .map((l) => ({
          id: l.id,
          fromName: l.fromName,
          toName: l.toName,
          startedAt: iso(l.startedAt),
          endedAt: iso(l.endedAt),
          distanceM: l.distanceM,
        })),
    }));
    if (page.length < VOYAGE_PAGE) return;
    after = (page[page.length - 1] as { id: string }).id;
  }
}

/** One track file of the export, as listed when the part (or manifest) was planned. */
export type TrackRef = {
  name: string;
  key: string;
  /** Set for session tracks, whose key changes with every upload revision. */
  sessionId?: string;
  etag?: string;
  size: number;
};

/**
 * Every track the account holds, in a stable order (sessions by start, then voyage legs),
 * with sizes and ETags from one listing of the user's prefix.
 */
async function trackRefs(db: Db, bucket: R2Bucket, userId: string): Promise<TrackRef[]> {
  const listed = new Map<string, { size: number; etag: string }>();
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix: userPrefix(userId), cursor, limit: 1000 });
    for (const o of page.objects) listed.set(o.key, { size: o.size, etag: o.etag });
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  const [sessionRows, legRows] = await Promise.all([
    db
      .select({ id: sessions.id, trackKey: sessions.trackKey })
      .from(sessions)
      .where(
        and(eq(sessions.userId, userId), isNull(sessions.deletedAt), isNotNull(sessions.trackKey)),
      )
      .orderBy(asc(sessions.startedAt), asc(sessions.id)),
    db
      .select({ id: legs.id, voyageId: legs.voyageId })
      .from(legs)
      .where(eq(legs.userId, userId))
      .orderBy(asc(legs.voyageId), asc(legs.id)),
  ]);
  const refs: TrackRef[] = [];
  for (const s of sessionRows) {
    if (!s.trackKey) continue;
    const found = listed.get(s.trackKey);
    refs.push({
      name: sessionTrackName(s.id),
      key: s.trackKey,
      sessionId: s.id,
      etag: found?.etag,
      size: found?.size ?? 0,
    });
  }
  for (const l of legRows) {
    const key = legTrackKey(userId, l.voyageId, l.id);
    const found = listed.get(key);
    if (found) refs.push({ name: legTrackName(l.voyageId, l.id), key, ...found });
  }
  return refs;
}

/** Identifies the planned track list: a part request for another list is refused (409). */
async function fingerprint(refs: TrackRef[]): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(refs.map((r) => r.name).join("\n")),
  );
  return Array.from(new Uint8Array(digest).slice(0, 16), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}

/** Consecutive ranges of at most TRACKS_PER_PART tracks and about PART_TARGET_BYTES. */
export function planParts(sizes: number[]): { from: number; to: number; bytes: number }[] {
  const parts: { from: number; to: number; bytes: number }[] = [];
  let from = 0;
  let bytes = 0;
  sizes.forEach((size, i) => {
    const count = i - from;
    if (count > 0 && (count >= TRACKS_PER_PART || bytes + size > PART_TARGET_BYTES)) {
      parts.push({ from, to: i, bytes });
      from = i;
      bytes = 0;
    }
    bytes += size;
  });
  if (sizes.length > from) parts.push({ from, to: sizes.length, bytes });
  return parts;
}

export type ExportError = { file: string; reason: string; detail?: string };

/** A part's storage calls and streamed bytes; nothing past either limit is attempted. */
export class PartBudget {
  calls = 0;
  bytes = 0;
  constructor(
    readonly maxCalls = PART_MAX_STORAGE_CALLS,
    readonly maxBytes = PART_MAX_BYTES,
  ) {}
  /** Reserves `n` calls, or returns false when they would exceed the limit. */
  take(n: number): boolean {
    if (this.calls + n > this.maxCalls) return false;
    this.calls += n;
    return true;
  }
}

/**
 * Reads one track for the archive. The listed ETag must still match, so a track replaced
 * after planning is noticed: a session's current revision is then looked up again and
 * exported instead. Returns null, with an entry in `errors`, when the track is gone or the
 * part has no budget left for it. The byte limit is checked against the object actually
 * read, not the listing.
 */
export async function readTrack(
  ref: TrackRef,
  context: { db: Db; bucket: R2Bucket; userId: string },
  budget: PartBudget,
  errors: ExportError[],
): Promise<ReadableStream<Uint8Array> | null> {
  if (!budget.take(1)) {
    errors.push({ file: ref.name, reason: "request_budget" });
    return null;
  }
  const first = ref.etag
    ? await context.bucket.get(ref.key, { onlyIf: { etagMatches: ref.etag } })
    : await context.bucket.get(ref.key);
  // A failed precondition returns the object's metadata without a body.
  let object: R2ObjectBody | null = first && "body" in first ? (first as R2ObjectBody) : null;
  if (!object) {
    // Replaced or deleted since planning: the row names the current revision, if any.
    if (!budget.take(2)) {
      errors.push({ file: ref.name, reason: "request_budget" });
      return null;
    }
    let key: string | null = ref.key;
    if (ref.sessionId) {
      const [row] = await context.db
        .select({ trackKey: sessions.trackKey })
        .from(sessions)
        .where(
          and(
            eq(sessions.id, ref.sessionId),
            eq(sessions.userId, context.userId),
            isNull(sessions.deletedAt),
          ),
        );
      key = row?.trackKey ?? null;
    }
    object = key ? await context.bucket.get(key) : null;
  }
  if (!object) {
    errors.push({
      file: ref.name,
      reason: "missing",
      detail: "Deleted while the export was running.",
    });
    return null;
  }
  if (budget.bytes + object.size > budget.maxBytes) {
    await object.body.cancel();
    errors.push({
      file: ref.name,
      reason: "part_size_limit",
      detail: `${object.size} bytes did not fit in this part; download it from the session.`,
    });
    return null;
  }
  budget.bytes += object.size;
  return object.body;
}

const README = `MadeGood account export

The export comes in parts. The account part (…-account.zip) holds the documents; the
other parts hold track files, ${TRACKS_PER_PART} or fewer each.

account.json         Your profile and settings, and Apple's identifier for your sign-in.
sessions.json        Every session in your account: times, sport, title, notes, visibility,
                     statistics, the analysis summary and wind estimate, the bounding box.
privacy-zones.json   Your privacy zones (center and radius).
voyages.json         Private voyages and their legs, if you synced any.
tracks/sessions/     Each session's track as you uploaded it (gzipped JSON, track v1,
                     docs/formats.md in the MadeGood source). Privacy zones are not cut
                     out: these are your own files.
tracks/voyages/      Voyage leg tracks, in the same format.
errors.json          Only in a track part that could not include a file, with the reason.

Units are SI: metres, seconds, metres per second, degrees. Times are UTC (ISO 8601).
`;

const ExportPart = z.object({
  part: z.number().int(),
  url: z.string().openapi({ description: "Path of this part's ZIP, under the API root." }),
  filename: z.string(),
  contents: z.enum(["account", "tracks"]),
  tracks: z.number().int(),
  bytes: z.number().int().openapi({ description: "Planned bytes of track files." }),
});

const ExportManifest = z
  .object({
    createdAt: z.string(),
    trackCount: z.number().int(),
    trackBytes: z.number().int(),
    parts: z.array(ExportPart),
  })
  .openapi("ExportManifest");

const ExportQuery = z.object({
  part: z.coerce
    .number()
    .int()
    .min(1)
    .max(1 + EXPORT_MAX_TRACKS)
    .optional(),
  v: z
    .string()
    .regex(/^[0-9a-f]{32}$/)
    .optional(),
  from: z.coerce.number().int().min(0).optional(),
  to: z.coerce.number().int().min(1).optional(),
});

const exportRoute = createRoute({
  method: "get",
  path: "/me/export",
  operationId: "exportAccount",
  summary: "Download all of the signed-in user's data",
  description:
    "Without `part`: a JSON manifest listing the parts. Part 1 is a ZIP of `account.json`, " +
    "`sessions.json`, `privacy-zones.json`, `voyages.json` and a README. Later parts are ZIPs " +
    `of at most ${TRACKS_PER_PART} track files as uploaded (owner versions); fetch them with ` +
    "the manifest's `url`. A part request for a track list that has changed since the manifest " +
    "gets 409; fetch the manifest again. A file a part cannot include is listed in its " +
    `\`errors.json\`. Refused with 413 above ${EXPORT_MAX_TRACKS} track files.`,
  tags: ["account"],
  security: [{ bearerAuth: [] }],
  middleware: [requireAuth] as const,
  request: { query: ExportQuery },
  responses: {
    200: {
      description: "The manifest, or one part's archive.",
      content: {
        "application/json": { schema: ExportManifest },
        "application/zip": { schema: z.string().openapi({ format: "binary" }) },
      },
    },
    400: errorResponse("The part parameters are invalid."),
    401: errorResponse("Missing or invalid access token, or the account no longer exists."),
    409: errorResponse("The account's tracks changed since the manifest (`export_changed`)."),
    413: errorResponse("The account holds too many tracks to export (`export_too_large`)."),
  },
});

export const exportRoutes = createRouter<AuthEnv>();

exportRoutes.openapi(exportRoute, async (c) => {
  const userId = c.var.userId;
  const query = c.req.valid("query");
  const db = drizzle(c.env.DB);
  const [found] = await db.select().from(users).where(eq(users.id, userId));
  if (!found) return apiError(c, 401, "unauthorized", "The account no longer exists.");
  const user = found;
  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  c.header("Cache-Control", "private, no-store");

  const zip = (entries: AsyncIterable<ZipEntry>, filename: string) =>
    new Response(zipResponseBody(entries, now), {
      status: 200,
      headers: {
        "Content-Type": "application/zip",
        "Content-Disposition": `attachment; filename="${filename}"`,
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
      },
    });

  if (query.part === 1) {
    async function* entries(): AsyncGenerator<ZipEntry> {
      yield { name: "README.txt", data: async () => encoder.encode(README) };
      yield {
        name: "account.json",
        data: async () =>
          json({
            ...toUserBody(user),
            appleUserId: user.appleSub,
            exportedAt: now.toISOString(),
          }),
      };
      yield {
        name: "sessions.json",
        data: async () => toStream(jsonArray(sessionPages(db, userId))),
      };
      yield {
        name: "privacy-zones.json",
        data: async () => {
          const zones = await db.select().from(privacyZones).where(eq(privacyZones.userId, userId));
          return json(zones.map((z) => ({ id: z.id, lat: z.lat, lon: z.lon, radiusM: z.radiusM })));
        },
      };
      yield {
        name: "voyages.json",
        data: async () => toStream(jsonArray(voyagePages(db, userId))),
      };
    }
    return zip(entries(), `madegood-export-${day}-account.zip`);
  }

  const refs = await trackRefs(db, c.env.TRACKS, userId);
  if (refs.length > EXPORT_MAX_TRACKS) {
    return apiError(
      c,
      413,
      "export_too_large",
      "This account holds too many tracks to export. Download sessions one at a time instead.",
    );
  }
  const version = await fingerprint(refs);

  if (query.part === undefined) {
    const plan = planParts(refs.map((r) => r.size));
    return c.json(
      {
        createdAt: now.toISOString(),
        trackCount: refs.length,
        trackBytes: refs.reduce((sum, r) => sum + r.size, 0),
        parts: [
          {
            part: 1,
            url: "/me/export?part=1",
            filename: `madegood-export-${day}-account.zip`,
            contents: "account" as const,
            tracks: 0,
            bytes: 0,
          },
          ...plan.map((p, i) => ({
            part: i + 2,
            url: `/me/export?part=${i + 2}&v=${version}&from=${p.from}&to=${p.to}`,
            filename: `madegood-export-${day}-part-${i + 2}.zip`,
            contents: "tracks" as const,
            tracks: p.to - p.from,
            bytes: p.bytes,
          })),
        ],
      },
      200,
    );
  }

  const { from, to, v } = query;
  if (from === undefined || to === undefined || v === undefined) {
    return apiError(c, 400, "invalid_request", "A track part needs `v`, `from` and `to`.");
  }
  if (v !== version) {
    return apiError(c, 409, "export_changed", "Your tracks changed. Start the export again.");
  }
  if (to <= from || to - from > TRACKS_PER_PART || to > refs.length) {
    return apiError(c, 400, "invalid_request", "The track range is invalid.");
  }

  const budget = new PartBudget();
  const errors: ExportError[] = [];
  const context = { db, bucket: c.env.TRACKS, userId };
  async function* entries(): AsyncGenerator<ZipEntry> {
    for (const ref of refs.slice(from, to)) {
      yield { name: ref.name, data: () => readTrack(ref, context, budget, errors) };
    }
    yield { name: "errors.json", data: async () => (errors.length > 0 ? json(errors) : null) };
  }
  return zip(entries(), `madegood-export-${day}-part-${query.part}.zip`);
});
