import { and, asc, desc, eq, gte, inArray, isNull, lt, or } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { z } from "zod";
import { toUserBody } from "../auth/users";
import {
  type ExportJob,
  exportJobs,
  legs,
  privacyZones,
  type Session,
  sessions,
  users,
  voyages,
} from "../db/schema";
import { deletePrefix, userPrefix } from "./storage";
import { type ZipEntry, zipStream } from "./zip";

// Account export as a background job (docs/self-hosting.md, "Account export").
//
// POST /me/exports freezes a snapshot: the user's sessions (id, upload revision, track key
// and ETag) and voyages with their legs (track key and ETag), written to R2 as JSON, never
// held across steps in memory. The snapshot fixes the plan: an ordered list of items
// (session documents in files of SESSIONS_PER_FILE, voyage documents, then every track),
// so steps never re-page by mutable columns and a sync during the export cannot shift it.
//
// Each queue message builds one ZIP part from the plan's cursor and streams it into an R2
// multipart upload: at most PART_MAX_BYTES (ZIP32-safe), ITEMS_PER_PART items and
// PART_MAX_CALLS storage calls, then queues the next step. A track is read by its frozen
// key and ETag; if it was replaced or removed since, the version current at build time is
// exported instead (noted in the manifest), and one that is gone is listed in errors.json.
// The last step writes part 1: README, account.json, privacy-zones.json, errors.json and
// manifest.json, which lists every part and every file. Parts expire after EXPORT_TTL_MS;
// the scheduled sweep deletes them, resumes a job whose message was lost, and fails one
// that stays stuck.

export const SESSIONS_PER_FILE = 250;
export const VOYAGES_PER_FILE = 100;
/** ZIP32-safe and far below R2's object size limit. */
export const PART_MAX_BYTES = 500 * 1024 * 1024;
export const ITEMS_PER_PART = 400;
/** R2 and D1 calls one step may make (a request or consumer allows 1,000). */
export const PART_MAX_CALLS = 700;
/** R2 multipart chunk: all chunks but the last must be the same size, at least 5 MiB. */
export const UPLOAD_CHUNK_BYTES = 8 * 1024 * 1024;
export const EXPORT_TTL_MS = 7 * 24 * 3600 * 1000;
/** Exports a user may start per day. */
export const EXPORTS_PER_DAY = 3;
export const EXPORT_MAX_SESSIONS = 50_000;
/** A building job not touched for this long is resumed by the sweep. */
export const STUCK_AFTER_MS = 30 * 60 * 1000;
/** A job that is not ready by then is failed. */
export const GIVE_UP_AFTER_MS = 12 * 3600 * 1000;
/** Rows of finished exports are kept this long so the website can show what happened. */
export const ROW_TTL_MS = 30 * 24 * 3600 * 1000;
const D1_IN = 50;

type Db = ReturnType<typeof drizzle>;
type ExportEnv = Pick<Env, "DB" | "TRACKS"> & { EXPORTS?: Queue<ExportMessage> };

export const ExportMessage = z.object({
  v: z.literal(1),
  kind: z.literal("export"),
  exportId: z.string().uuid(),
  userId: z.string().min(1),
  cursor: z.number().int().min(0),
  part: z.number().int().min(2),
});
export type ExportMessage = z.infer<typeof ExportMessage>;

const Snapshot = z.object({
  v: z.literal(1),
  exportId: z.string(),
  userId: z.string(),
  createdAt: z.number(),
  sessions: z.array(
    z.object({
      id: z.string(),
      revision: z.number(),
      trackKey: z.string().nullable(),
      etag: z.string().nullable(),
    }),
  ),
  voyages: z.array(
    z.object({
      id: z.string(),
      legs: z.array(
        z.object({ id: z.string(), trackKey: z.string().nullable(), etag: z.string().nullable() }),
      ),
    }),
  ),
});
export type Snapshot = z.infer<typeof Snapshot>;

export const exportPrefix = (userId: string, exportId: string) =>
  `${userPrefix(userId)}exports/${exportId}/`;
const snapshotKey = (userId: string, exportId: string) =>
  `${exportPrefix(userId, exportId)}snapshot.json`;
export const partKey = (userId: string, exportId: string, part: number) =>
  `${exportPrefix(userId, exportId)}part-${part}.zip`;
const listingKey = (userId: string, exportId: string, part: number) =>
  `${exportPrefix(userId, exportId)}part-${part}.json`;
const legTrackKey = (userId: string, voyageId: string, legId: string) =>
  `${userPrefix(userId)}voyages/${voyageId}/legs/${legId}/track.v1.gz`;

const encoder = new TextEncoder();
const json = (value: unknown) => encoder.encode(`${JSON.stringify(value, null, 2)}\n`);
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());
const parseJson = (text: string | null): unknown => {
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};
const pad = (n: number) => String(n).padStart(4, "0");

// ---------------------------------------------------------------------------------------
// Plan

export type Item =
  | { kind: "sessions"; name: string; ids: string[] }
  | { kind: "voyages"; name: string; ids: string[] }
  | {
      kind: "track";
      name: string;
      key: string;
      etag: string | null;
      sessionId?: string;
    };

/** The snapshot's ordered items. Pure: the same snapshot always gives the same plan. */
export function planItems(snapshot: Snapshot): Item[] {
  const items: Item[] = [];
  for (let i = 0; i < snapshot.sessions.length; i += SESSIONS_PER_FILE) {
    items.push({
      kind: "sessions",
      name: `sessions/sessions-${pad(i / SESSIONS_PER_FILE + 1)}.json`,
      ids: snapshot.sessions.slice(i, i + SESSIONS_PER_FILE).map((s) => s.id),
    });
  }
  for (let i = 0; i < snapshot.voyages.length; i += VOYAGES_PER_FILE) {
    items.push({
      kind: "voyages",
      name: `voyages/voyages-${pad(i / VOYAGES_PER_FILE + 1)}.json`,
      ids: snapshot.voyages.slice(i, i + VOYAGES_PER_FILE).map((v) => v.id),
    });
  }
  for (const s of snapshot.sessions) {
    if (s.trackKey) {
      items.push({
        kind: "track",
        name: `tracks/sessions/${s.id}.track.v1.gz`,
        key: s.trackKey,
        etag: s.etag,
        sessionId: s.id,
      });
    }
  }
  for (const v of snapshot.voyages) {
    for (const l of v.legs) {
      if (l.trackKey) {
        items.push({
          kind: "track",
          name: `tracks/voyages/${v.id}/${l.id}.track.v1.gz`,
          key: l.trackKey,
          etag: l.etag,
        });
      }
    }
  }
  return items;
}

// ---------------------------------------------------------------------------------------
// Creating a job

export type CreateResult =
  | { kind: "created"; job: ExportJob }
  | { kind: "in_progress"; job: ExportJob }
  | { kind: "rate_limited" }
  | { kind: "too_large" };

/** Freezes the snapshot and records the job; the caller then sends its first message. */
export async function createExportJob(
  env: ExportEnv,
  userId: string,
  now = Date.now(),
): Promise<CreateResult> {
  const db = drizzle(env.DB);
  const [active] = await db
    .select()
    .from(exportJobs)
    .where(
      and(
        eq(exportJobs.userId, userId),
        or(eq(exportJobs.status, "queued"), eq(exportJobs.status, "building")),
      ),
    );
  if (active) return { kind: "in_progress", job: active };
  const recent = await db
    .select({ id: exportJobs.id })
    .from(exportJobs)
    .where(and(eq(exportJobs.userId, userId), gte(exportJobs.createdAt, now - 24 * 3600 * 1000)));
  if (recent.length >= EXPORTS_PER_DAY) return { kind: "rate_limited" };

  const sessionRows = await db
    .select({
      id: sessions.id,
      revision: sessions.uploadRevision,
      trackKey: sessions.trackKey,
      etag: sessions.trackEtag,
    })
    .from(sessions)
    .where(and(eq(sessions.userId, userId), isNull(sessions.deletedAt)))
    .orderBy(asc(sessions.startedAt), asc(sessions.id));
  if (sessionRows.length > EXPORT_MAX_SESSIONS) return { kind: "too_large" };
  const [voyageRows, legRows] = await Promise.all([
    db
      .select({ id: voyages.id })
      .from(voyages)
      .where(eq(voyages.userId, userId))
      .orderBy(asc(voyages.id)),
    db
      .select({ id: legs.id, voyageId: legs.voyageId })
      .from(legs)
      .where(eq(legs.userId, userId))
      .orderBy(asc(legs.voyageId), asc(legs.id)),
  ]);
  // Leg tracks have fixed keys; their ETags come from one listing of the voyages prefix.
  const legObjects = new Map<string, string>();
  let cursor: string | undefined;
  do {
    const page = await env.TRACKS.list({ prefix: `${userPrefix(userId)}voyages/`, cursor });
    for (const o of page.objects) legObjects.set(o.key, o.etag);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  const exportId = crypto.randomUUID();
  const snapshot: Snapshot = {
    v: 1,
    exportId,
    userId,
    createdAt: now,
    sessions: sessionRows.map((s) => ({
      id: s.id,
      revision: s.revision,
      trackKey: s.trackKey,
      etag: s.trackKey ? (s.etag ?? null) : null,
    })),
    voyages: voyageRows.map((v) => ({
      id: v.id,
      legs: legRows
        .filter((l) => l.voyageId === v.id)
        .map((l) => {
          const key = legTrackKey(userId, v.id, l.id);
          const etag = legObjects.get(key);
          return { id: l.id, trackKey: etag ? key : null, etag: etag ?? null };
        }),
    })),
  };
  await env.TRACKS.put(snapshotKey(userId, exportId), JSON.stringify(snapshot), {
    httpMetadata: { contentType: "application/json" },
  });
  const [job] = await db
    .insert(exportJobs)
    .values({
      id: exportId,
      userId,
      status: "queued",
      totalItems: planItems(snapshot).length,
      createdAt: now,
      updatedAt: now,
    })
    .returning();
  if (!job) throw new Error("could not record the export job");
  return { kind: "created", job };
}

export const firstMessage = (job: ExportJob): ExportMessage => ({
  v: 1,
  kind: "export",
  exportId: job.id,
  userId: job.userId,
  cursor: job.cursor,
  part: job.nextPart,
});

/**
 * Sends a step to the EXPORTS queue. Without the binding (previews, or a self-hosted copy
 * without Queues) it runs the steps after the response with waitUntil instead, for as long
 * as that allows; the scheduled sweep resumes whatever is left.
 */
export async function sendExportStep(
  env: ExportEnv,
  ctx: Pick<ExecutionContext, "waitUntil"> | null,
  message: ExportMessage,
): Promise<void> {
  if (env.EXPORTS) {
    await env.EXPORTS.send(message);
    return;
  }
  const run = async () => {
    const started = Date.now();
    let next: ExportMessage | null = message;
    while (next && Date.now() - started < 20_000) next = await runExportStep(env, next);
  };
  if (ctx) ctx.waitUntil(run().catch((error) => console.error("Export step failed.", error)));
  else await run();
}

// ---------------------------------------------------------------------------------------
// Building

type PartListing = {
  part: number;
  files: { name: string; note?: string }[];
  errors: { file: string; reason: string; detail?: string }[];
};

/** Per-part limits; tests pass smaller ones to exercise many parts. */
export type PartLimits = { maxBytes: number; maxItems: number; maxCalls: number };
export const PART_LIMITS: PartLimits = {
  maxBytes: PART_MAX_BYTES,
  maxItems: ITEMS_PER_PART,
  maxCalls: PART_MAX_CALLS,
};

class Calls {
  used = 0;
  constructor(readonly max = PART_MAX_CALLS) {}
  take(n = 1) {
    this.used += n;
  }
  get left() {
    return this.max - this.used;
  }
}

const accountActive = async (db: Db, userId: string) =>
  (
    await db
      .select({ id: users.id })
      .from(users)
      .where(and(eq(users.id, userId), isNull(users.deletedAt)))
  ).length > 0;

/** Streams `chunks` into an R2 multipart upload in fixed-size chunks; returns the bytes. */
async function uploadStream(
  bucket: R2Bucket,
  key: string,
  chunks: AsyncIterable<Uint8Array>,
  calls: Calls,
): Promise<number> {
  calls.take(2); // create and complete
  const upload = await bucket.createMultipartUpload(key, {
    httpMetadata: { contentType: "application/zip" },
  });
  const uploaded: R2UploadedPart[] = [];
  let buffer = new Uint8Array(UPLOAD_CHUNK_BYTES);
  let filled = 0;
  let total = 0;
  const flush = async () => {
    calls.take();
    uploaded.push(await upload.uploadPart(uploaded.length + 1, buffer.slice(0, filled)));
    buffer = new Uint8Array(UPLOAD_CHUNK_BYTES);
    filled = 0;
  };
  try {
    for await (const chunk of chunks) {
      let offset = 0;
      while (offset < chunk.length) {
        const n = Math.min(chunk.length - offset, UPLOAD_CHUNK_BYTES - filled);
        buffer.set(chunk.subarray(offset, offset + n), filled);
        filled += n;
        offset += n;
        total += n;
        if (filled === UPLOAD_CHUNK_BYTES) await flush();
      }
    }
    if (filled > 0 || uploaded.length === 0) await flush();
    await upload.complete(uploaded);
  } catch (error) {
    await upload.abort().catch(() => {});
    throw error;
  }
  return total;
}

type SessionRow = Session;
const sessionDocument = (s: SessionRow, trackName: string | null) => ({
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
  trackStartedAt: iso(s.trackStartedAt),
  trackEndedAt: iso(s.trackEndedAt),
  summary: parseJson(s.summaryJson),
  wind: parseJson(s.windJson),
  analyzerVersion: s.analyzerVersion,
  uploadRevision: s.uploadRevision,
  track: trackName,
  createdAt: iso(s.createdAt),
  updatedAt: iso(s.updatedAt),
});

/** Reads an item's bytes (documents) or body (tracks); null when it is gone. */
async function readItem(
  env: ExportEnv,
  db: Db,
  userId: string,
  item: Item,
  calls: Calls,
  listing: PartListing,
): Promise<{ data: Uint8Array | ReadableStream<Uint8Array>; size: number } | null> {
  if (item.kind === "sessions") {
    const rows: SessionRow[] = [];
    for (let i = 0; i < item.ids.length; i += D1_IN) {
      calls.take();
      rows.push(
        ...(await db
          .select()
          .from(sessions)
          .where(
            and(
              eq(sessions.userId, userId),
              isNull(sessions.deletedAt),
              inArray(sessions.id, item.ids.slice(i, i + D1_IN)),
            ),
          )),
      );
    }
    const byId = new Map(rows.map((r) => [r.id, r]));
    const docs = [];
    for (const id of item.ids) {
      const row = byId.get(id);
      if (!row) {
        listing.errors.push({
          file: `${item.name}#${id}`,
          reason: "deleted",
          detail: "The session was deleted after the export started.",
        });
        continue;
      }
      docs.push(sessionDocument(row, row.trackKey ? `tracks/sessions/${id}.track.v1.gz` : null));
    }
    const bytes = json(docs);
    return { data: bytes, size: bytes.length };
  }
  if (item.kind === "voyages") {
    calls.take(2);
    const [voyageRows, legRows] = await Promise.all([
      db
        .select()
        .from(voyages)
        .where(and(eq(voyages.userId, userId), inArray(voyages.id, item.ids))),
      db
        .select()
        .from(legs)
        .where(and(eq(legs.userId, userId), inArray(legs.voyageId, item.ids)))
        .orderBy(asc(legs.startedAt), asc(legs.id)),
    ]);
    const byId = new Map(voyageRows.map((v) => [v.id, v]));
    const docs = item.ids.flatMap((id) => {
      const v = byId.get(id);
      if (!v) return [];
      return [
        {
          id: v.id,
          title: v.title,
          boatName: v.boatName,
          startedAt: iso(v.startedAt),
          endedAt: iso(v.endedAt),
          legs: legRows
            .filter((l) => l.voyageId === id)
            .map((l) => ({
              id: l.id,
              fromName: l.fromName,
              toName: l.toName,
              startedAt: iso(l.startedAt),
              endedAt: iso(l.endedAt),
              distanceM: l.distanceM,
            })),
        },
      ];
    });
    const bytes = json(docs);
    return { data: bytes, size: bytes.length };
  }

  // A track: the frozen version, else the one current now, else an error entry.
  calls.take();
  const first = item.etag
    ? await env.TRACKS.get(item.key, { onlyIf: { etagMatches: item.etag } })
    : await env.TRACKS.get(item.key);
  if (first && "body" in first) {
    const object = first as R2ObjectBody;
    return { data: object.body, size: object.size };
  }
  let key: string | null = item.key;
  if (item.sessionId) {
    calls.take();
    const [row] = await db
      .select({ trackKey: sessions.trackKey })
      .from(sessions)
      .where(
        and(
          eq(sessions.id, item.sessionId),
          eq(sessions.userId, userId),
          isNull(sessions.deletedAt),
        ),
      );
    key = row?.trackKey ?? null;
  }
  calls.take();
  const current = key ? await env.TRACKS.get(key) : null;
  if (current) {
    listing.files.push({
      name: item.name,
      note: "Replaced after the export started; this is the version current when it was built.",
    });
    return { data: current.body, size: current.size };
  }
  listing.errors.push({
    file: item.name,
    reason: "missing",
    detail: "Deleted after the export started.",
  });
  return null;
}

/** ZIP bytes an entry adds: local header, data, descriptor, and its central record. */
const entryBytes = (name: string, size: number) => {
  const n = encoder.encode(name).length;
  return 30 + n + size + 16 + 46 + n;
};

/**
 * Builds the data part `part` from `cursor`; returns the cursor after the last item it took.
 * Always takes at least one item, so every step makes progress.
 */
async function buildDataPart(
  env: ExportEnv,
  db: Db,
  userId: string,
  exportId: string,
  items: Item[],
  cursor: number,
  part: number,
  calls: Calls,
  limits: PartLimits,
): Promise<{ cursor: number; bytes: number }> {
  const listing: PartListing = { part, files: [], errors: [] };
  let next = cursor;
  let used = 22; // end of central directory
  async function* entries(): AsyncGenerator<ZipEntry> {
    while (next < items.length && next - cursor < limits.maxItems && calls.left > 20) {
      const item = items[next] as Item;
      const errorsBefore = listing.errors.length;
      const read = await readItem(env, db, userId, item, calls, listing);
      if (read === null) {
        next += 1;
        continue;
      }
      const size = entryBytes(item.name, read.size);
      if (next > cursor && used + size > limits.maxBytes) {
        // Next part. The item is read again there (by the same rules).
        if (read.data instanceof ReadableStream) await read.data.cancel();
        const last = listing.files.at(-1);
        if (last?.name === item.name) listing.files.pop();
        listing.errors.length = errorsBefore;
        return;
      }
      used += size;
      next += 1;
      if (!listing.files.some((f) => f.name === item.name)) listing.files.push({ name: item.name });
      yield { name: item.name, data: async () => read.data };
    }
  }
  const bytes = await uploadStream(
    env.TRACKS,
    partKey(userId, exportId, part),
    zipStream(entries(), new Date()),
    calls,
  );
  calls.take();
  await env.TRACKS.put(listingKey(userId, exportId, part), JSON.stringify(listing));
  return { cursor: next, bytes };
}

const README = `MadeGood account export

Your data comes in several ZIP files ("parts"). This one, part 1, holds:

manifest.json        Every part and every file in it. Check it to see that you have all parts.
account.json         Your profile and settings, and Apple's identifier for your sign-in.
privacy-zones.json   Your privacy zones (center and radius).
errors.json          Only if a file could not be included, with the reason.

The other parts hold:

sessions/            Every session in your account (when the export started): times, sport,
                     title, notes, visibility, statistics, the analysis summary, the area and
                     times worked out from the track, and the wind estimate. ${SESSIONS_PER_FILE} per file.
voyages/             Private voyages and their legs, if you synced any.
tracks/sessions/     Each session's track as you uploaded it (gzipped JSON, track v1,
                     docs/formats.md in the MadeGood source). Privacy zones are not cut out:
                     these are your own files.
tracks/voyages/      Voyage leg tracks, in the same format.

Units are SI: metres, seconds, metres per second, degrees. Times are UTC (ISO 8601).
`;

/** Writes part 1 (documents and the manifest) from the parts' listings. */
async function buildFirstPart(
  env: ExportEnv,
  db: Db,
  job: ExportJob,
  snapshot: Snapshot,
  calls: Calls,
): Promise<number> {
  const parts = JSON.parse(job.partsJson) as { part: number; bytes: number }[];
  const listings: PartListing[] = [];
  for (const p of parts) {
    calls.take();
    const object = await env.TRACKS.get(listingKey(job.userId, job.id, p.part));
    if (object) listings.push(await object.json<PartListing>());
  }
  calls.take(3);
  const [user] = await db.select().from(users).where(eq(users.id, job.userId));
  const zones = await db.select().from(privacyZones).where(eq(privacyZones.userId, job.userId));
  if (!user) throw new Error("the account is gone");
  const errors = listings.flatMap((l) => l.errors);
  const firstFiles = ["README.txt", "account.json", "privacy-zones.json", "manifest.json"];
  if (errors.length > 0) firstFiles.push("errors.json");
  const manifest = {
    exportId: job.id,
    createdAt: iso(snapshot.createdAt),
    sessions: snapshot.sessions.length,
    voyages: snapshot.voyages.length,
    parts: [
      { part: 1, files: firstFiles.map((name) => ({ name })) },
      ...listings.map((l) => ({ part: l.part, files: l.files })),
    ],
    errors: errors.length,
  };
  async function* entries(): AsyncGenerator<ZipEntry> {
    yield { name: "README.txt", data: async () => encoder.encode(README) };
    yield {
      name: "account.json",
      data: async () =>
        json({ ...toUserBody(user as typeof users.$inferSelect), appleUserId: user?.appleSub }),
    };
    yield {
      name: "privacy-zones.json",
      data: async () =>
        json(zones.map((z) => ({ id: z.id, lat: z.lat, lon: z.lon, radiusM: z.radiusM }))),
    };
    yield { name: "manifest.json", data: async () => json(manifest) };
    if (errors.length > 0) yield { name: "errors.json", data: async () => json(errors) };
  }
  return uploadStream(
    env.TRACKS,
    partKey(job.userId, job.id, 1),
    zipStream(entries(), new Date()),
    calls,
  );
}

/**
 * One step of an export: builds the next part and returns the following message, or null
 * when the job is finished, failed or the message is stale (a duplicate or an old step).
 * Throws on storage failures; the queue retries and the sweep resumes.
 */
export async function runExportStep(
  env: ExportEnv,
  message: ExportMessage,
  now = () => Date.now(),
  limits: PartLimits = PART_LIMITS,
): Promise<ExportMessage | null> {
  const db = drizzle(env.DB);
  const [job] = await db.select().from(exportJobs).where(eq(exportJobs.id, message.exportId));
  if (!job || job.userId !== message.userId) return null;
  if (job.status !== "queued" && job.status !== "building") return null;
  if (job.cursor !== message.cursor || job.nextPart !== message.part) return null;
  if (!(await accountActive(db, job.userId))) {
    await failJob(env, job, "The account is being deleted.");
    return null;
  }
  const object = await env.TRACKS.get(snapshotKey(job.userId, job.id));
  if (!object) {
    await failJob(env, job, "The export's snapshot is missing.");
    return null;
  }
  const snapshot = Snapshot.parse(await object.json());
  const items = planItems(snapshot);
  const calls = new Calls(limits.maxCalls);
  const current = and(
    eq(exportJobs.id, job.id),
    eq(exportJobs.cursor, job.cursor),
    eq(exportJobs.nextPart, job.nextPart),
  );

  if (job.cursor < items.length) {
    const built = await buildDataPart(
      env,
      db,
      job.userId,
      job.id,
      items,
      job.cursor,
      job.nextPart,
      calls,
      limits,
    );
    const parts = [
      ...(JSON.parse(job.partsJson) as { part: number; bytes: number }[]),
      { part: job.nextPart, bytes: built.bytes },
    ];
    const [updated] = await db
      .update(exportJobs)
      .set({
        status: "building",
        cursor: built.cursor,
        nextPart: job.nextPart + 1,
        partsJson: JSON.stringify(parts),
        updatedAt: now(),
      })
      .where(current)
      .returning();
    if (!updated) {
      await dropIfJobGone(env, db, job);
      return null;
    }
    if (!(await accountActive(db, job.userId))) {
      await failJob(env, updated, "The account is being deleted.");
      return null;
    }
    return firstMessage(updated);
  }

  const bytes = await buildFirstPart(env, db, job, snapshot, calls);
  const parts = [
    { part: 1, bytes },
    ...(JSON.parse(job.partsJson) as { part: number; bytes: number }[]),
  ];
  const [done] = await db
    .update(exportJobs)
    .set({
      status: "ready",
      partsJson: JSON.stringify(parts),
      updatedAt: now(),
      expiresAt: now() + EXPORT_TTL_MS,
    })
    .where(current)
    .returning();
  if (!done) await dropIfJobGone(env, db, job);
  if (done && !(await accountActive(db, job.userId))) {
    await failJob(env, done, "The account is being deleted.");
  }
  return null;
}

/**
 * After a lost compare-and-swap: a duplicate step may have won (its part has the same key,
 * so it stays), or the job is gone with its account, and then what this step wrote goes.
 */
async function dropIfJobGone(env: ExportEnv, db: Db, job: ExportJob) {
  const [still] = await db
    .select({ id: exportJobs.id })
    .from(exportJobs)
    .where(eq(exportJobs.id, job.id));
  if (!still) await deletePrefix(env.TRACKS, exportPrefix(job.userId, job.id));
}

async function failJob(env: ExportEnv, job: ExportJob, error: string) {
  await deletePrefix(env.TRACKS, exportPrefix(job.userId, job.id));
  await drizzle(env.DB)
    .update(exportJobs)
    .set({ status: "failed", error, updatedAt: Date.now(), partsJson: "[]" })
    .where(eq(exportJobs.id, job.id));
}

/** The EXPORTS queue consumer (max_batch_size 1: one part per invocation). */
export async function handleExportBatch(batch: MessageBatch<unknown>, env: Env): Promise<void> {
  for (const message of batch.messages) {
    const parsed = ExportMessage.safeParse(message.body);
    if (!parsed.success) {
      console.warn("Dropping a malformed export message.");
      message.ack();
      continue;
    }
    try {
      const next = await runExportStep(env, parsed.data);
      if (next) await sendExportStep(env, null, next);
      message.ack();
    } catch (error) {
      console.error("Export step failed; retrying.", error);
      message.retry({ delaySeconds: 30 * message.attempts });
    }
  }
}

// ---------------------------------------------------------------------------------------
// Scheduled sweep

/** Expires finished exports, resumes stuck ones, fails hopeless ones, drops old rows. */
export async function sweepExports(
  env: ExportEnv,
  ctx: Pick<ExecutionContext, "waitUntil"> | null,
  now = Date.now(),
): Promise<{ expired: number; resumed: number; failed: number; removed: number }> {
  const db = drizzle(env.DB);
  const counts = { expired: 0, resumed: 0, failed: 0, removed: 0 };
  const expired = await db
    .select()
    .from(exportJobs)
    .where(and(eq(exportJobs.status, "ready"), lt(exportJobs.expiresAt, now)))
    .limit(50);
  for (const job of expired) {
    await deletePrefix(env.TRACKS, exportPrefix(job.userId, job.id));
    await db
      .update(exportJobs)
      .set({ status: "expired", partsJson: "[]", updatedAt: now })
      .where(eq(exportJobs.id, job.id));
    counts.expired += 1;
  }
  const stuck = await db
    .select()
    .from(exportJobs)
    .where(
      and(
        or(eq(exportJobs.status, "queued"), eq(exportJobs.status, "building")),
        lt(exportJobs.updatedAt, now - STUCK_AFTER_MS),
      ),
    )
    .limit(50);
  for (const job of stuck) {
    if (job.createdAt < now - GIVE_UP_AFTER_MS) {
      await failJob(env, job, "The export did not finish in time. Start it again.");
      counts.failed += 1;
    } else {
      await db.update(exportJobs).set({ updatedAt: now }).where(eq(exportJobs.id, job.id));
      await sendExportStep(env, ctx, firstMessage(job));
      counts.resumed += 1;
    }
  }
  const old = await db
    .delete(exportJobs)
    .where(
      and(
        or(eq(exportJobs.status, "expired"), eq(exportJobs.status, "failed")),
        lt(exportJobs.updatedAt, now - ROW_TTL_MS),
      ),
    )
    .returning({ id: exportJobs.id });
  counts.removed = old.length;
  return counts;
}

/** The user's most recent exports, newest first. */
export const recentExports = (db: Db, userId: string, limit = 5) =>
  db
    .select()
    .from(exportJobs)
    .where(eq(exportJobs.userId, userId))
    .orderBy(desc(exportJobs.createdAt))
    .limit(limit);
