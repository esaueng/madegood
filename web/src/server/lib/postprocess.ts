import { z } from "@hono/zod-openapi";
import { and, asc, eq, gt, isNotNull, isNull, lt, ne, or, type SQL, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { privacyZones, type Session, sessions, users } from "../db/schema";
import type { Zone } from "./session-privacy";
import { userPrefix } from "./storage";
import {
  parseGzippedJson,
  SHARED_TRACK_MAX_INFLATED_BYTES,
  TrackTooLarge,
  trackKey,
} from "./track";
import { boundsCenter, deriveTrack, InvalidTrack, type TrackDerived } from "./track-derived";
import { fetchWind, type StoredWind, WindTransientError, windRequest } from "./wind";

// Upload post-processing (docs/PLAN.md §7). A track upload enqueues one message per
// (session, revision, track ETag); the consumer derives the bounds, start geohash and time
// range from the stored track, then, for sessions others can see, fetches wind. Every
// write is conditional on the row still holding that exact track, so duplicates, stale
// revisions and deleted sessions are dropped, and redelivery is harmless.
//
// Public data (public_*) is cut with the owner's privacy zones. It carries the
// users.zones_version it was computed at, is written only while that version is still
// current, and is served only while it matches (routes/sessions.ts). A zone change bumps
// the version in the same D1 batch, so no box or time computed without a zone is ever
// served after the zone exists, and queues one `user` message that requeues every
// session whose public data is behind.
//
// Memory: the track is inflated as a stream with the shared-track caps from #64
// (SHARED_TRACK_MAX_INFLATED_BYTES, SHARED_TRACK_MAX_FIXES). A larger track is marked
// `too_large` and gets no derived data, as it gets no shared copy.

export const SessionMessage = z.object({
  v: z.literal(1),
  kind: z.literal("session").optional(),
  sessionId: z.string().uuid(),
  userId: z.string().min(1),
  revision: z.number().int().min(0),
  etag: z.string().min(1),
});
/** Requeue the user's sessions whose public data predates their zones, from `after` on. */
export const UserMessage = z.object({
  v: z.literal(1),
  kind: z.literal("user"),
  userId: z.string().min(1),
  after: z.string().optional(),
});
export const PostprocessMessage = z.union([UserMessage, SessionMessage]);
export type SessionMessage = z.infer<typeof SessionMessage>;
export type UserMessage = z.infer<typeof UserMessage>;
export type PostprocessMessage = z.infer<typeof PostprocessMessage>;

/** Sessions a `user` message requeues before passing the rest to a follow-up message. */
export const USER_PAGE = 50;
/** Without a queue, how many sessions one zone change reprocesses inline (waitUntil). */
export const INLINE_USER_LIMIT = 20;

const PUBLIC_FIELDS = {
  publicMinLat: null,
  publicMinLon: null,
  publicMaxLat: null,
  publicMaxLon: null,
  publicTrackStartedAt: null,
  publicTrackEndedAt: null,
  publicZonesVersion: null,
} as const;

/** The columns post-processing owns, cleared whenever the attached track changes. */
export const CLEARED_DERIVED = {
  processedEtag: null,
  postprocessStatus: null,
  trackStartedAt: null,
  trackEndedAt: null,
  minLat: null,
  minLon: null,
  maxLat: null,
  maxLon: null,
  startGeohash: null,
  ...PUBLIC_FIELDS,
  windJson: null,
} as const;

/** Retry delays for a failed message: 30 s, 1, 2, 4, 8 min (wrangler.jsonc max_retries 5). */
export const retryDelaySeconds = (attempts: number) =>
  Math.min(30 * 2 ** Math.max(0, attempts - 1), 3600);

type Db = ReturnType<typeof drizzle>;

/** What a message led to; tests read it, the queue handler acks or retries on it. */
export type Outcome =
  | "processed"
  | "wind_only"
  | "skipped_stale"
  | "skipped_done"
  | "too_large"
  | "invalid"
  | "invalid_message"
  | "user_requeued";

export class RetryLater extends Error {}

/** The owner's zones and zones version, read in one batch (one snapshot). */
async function loadZones(
  db: Db,
  userId: string,
): Promise<{ zones: Zone[]; version: number } | null> {
  const [zones, owner] = await db.batch([
    db
      .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
      .from(privacyZones)
      .where(eq(privacyZones.userId, userId)),
    db.select({ version: users.zonesVersion }).from(users).where(eq(users.id, userId)),
  ]);
  const version = owner[0]?.version;
  return version === undefined ? null : { zones, version };
}

/** True while the owner's zones version is still `version`. */
const zonesStillAt = (userId: string, version: number): SQL =>
  sql`(SELECT ${users.zonesVersion} FROM ${users} WHERE ${users.id} = ${userId}) = ${version}`;

/** Whether others may be shown this session's public data, given the owner's version. */
export const publicIsCurrent = (
  s: Pick<Session, "publicZonesVersion">,
  zonesVersion: number | null | undefined,
) => zonesVersion != null && s.publicZonesVersion === zonesVersion;

export type ProcessDeps = {
  fetch?: typeof fetch;
  now?: () => number;
  /** Test hooks that force interleavings. */
  hooks?: { afterDerive?: () => Promise<void>; beforeWind?: () => Promise<void> };
};

type ProcessEnv = Pick<Env, "DB" | "TRACKS"> & { POSTPROCESS?: Queue<PostprocessMessage> };

/**
 * Processes one message. Returns the outcome, or throws when the message should be
 * retried (RetryLater, WindTransientError, or any D1/R2/queue failure).
 */
export async function processMessage(
  env: ProcessEnv,
  raw: unknown,
  deps: ProcessDeps = {},
): Promise<Outcome> {
  const parsed = PostprocessMessage.safeParse(raw);
  if (!parsed.success) return "invalid_message";
  const msg = parsed.data;
  if (msg.kind === "user") {
    await requeueUser(env, msg);
    return "user_requeued";
  }
  return processSession(env, msg, deps);
}

/** How many times a session message recomputes at once when zones change under it. */
const ZONE_RACE_ATTEMPTS = 3;

export async function processSession(
  env: Pick<Env, "DB" | "TRACKS">,
  raw: unknown,
  deps: ProcessDeps = {},
): Promise<Outcome> {
  const parsed = SessionMessage.safeParse(raw);
  if (!parsed.success) return "invalid_message";
  const msg = parsed.data;
  const db = drizzle(env.DB);
  const key = trackKey(userPrefix(msg.userId), msg.sessionId, msg.revision);
  // The row as long as it still holds this message's track.
  const current = and(
    eq(sessions.id, msg.sessionId),
    eq(sessions.userId, msg.userId),
    isNull(sessions.deletedAt),
    eq(sessions.uploadRevision, msg.revision),
    eq(sessions.trackKey, key),
    eq(sessions.trackEtag, msg.etag),
  );

  let outcome: Outcome = "skipped_done";
  let session: Session | undefined;
  for (let attempt = 0; ; attempt++) {
    const [row] = await db.select().from(sessions).where(current);
    if (!row) return "skipped_stale";
    const owner = await loadZones(db, msg.userId);
    if (!owner) return "skipped_stale";
    // Done only when processed from this track *and* public data is at the current zones.
    if (row.processedEtag === msg.etag && publicIsCurrent(row, owner.version)) {
      if (row.postprocessStatus !== "done") return outcome;
      session = row;
      break;
    }
    if (attempt >= ZONE_RACE_ATTEMPTS) throw new RetryLater("privacy zones keep changing");

    const object = await env.TRACKS.get(key);
    // Replaced or deleted since; the newer upload has its own message.
    if (!object || object.etag !== msg.etag) {
      await object?.body.cancel();
      return "skipped_stale";
    }
    let derived: TrackDerived | null = null;
    let status: "done" | "too_large" | "invalid" = "done";
    try {
      derived = deriveTrack(
        await parseGzippedJson(object.body, SHARED_TRACK_MAX_INFLATED_BYTES),
        msg.sessionId,
        owner.zones,
      );
    } catch (error) {
      if (error instanceof TrackTooLarge) status = "too_large";
      else if (error instanceof InvalidTrack || error instanceof SyntaxError) status = "invalid";
      else if (error instanceof TypeError) {
        status = "invalid"; // corrupt gzip data
      } else throw error;
    }
    await deps.hooks?.afterDerive?.();
    // Written only while the owner's zones are still the ones read above.
    const [written] = await db
      .update(sessions)
      .set({
        processedEtag: msg.etag,
        postprocessStatus: status,
        trackStartedAt: derived?.startedAt ?? null,
        trackEndedAt: derived?.endedAt ?? null,
        minLat: derived?.bounds?.south ?? null,
        minLon: derived?.bounds?.west ?? null,
        maxLat: derived?.bounds?.north ?? null,
        maxLon: derived?.bounds?.east ?? null,
        startGeohash: derived?.startGeohash ?? null,
        publicMinLat: derived?.publicBounds?.south ?? null,
        publicMinLon: derived?.publicBounds?.west ?? null,
        publicMaxLat: derived?.publicBounds?.north ?? null,
        publicMaxLon: derived?.publicBounds?.east ?? null,
        publicTrackStartedAt: derived?.publicStartedAt ?? null,
        publicTrackEndedAt: derived?.publicEndedAt ?? null,
        publicZonesVersion: owner.version,
      })
      .where(and(current, zonesStillAt(msg.userId, owner.version)))
      .returning();
    if (written) {
      if (status !== "done") return status;
      session = written;
      outcome = "processed";
      break;
    }
    // Either the track changed (the next read returns stale) or the zones did: go again.
  }

  if (!needsWind(session)) return outcome;
  const version = session.publicZonesVersion;
  if (version === null) return outcome;
  const wind = await lookupWind(db, session, current, deps);
  if (!wind) return outcome;
  // Wind is public data like the bounds: it is stored only while the row still holds this
  // processed track, is still shared, has none, and its public data is still at the
  // owner's current zones version (a zone change clears wind with the rest).
  await db
    .update(sessions)
    .set({ windJson: JSON.stringify(wind) })
    .where(
      and(
        current,
        eq(sessions.processedEtag, msg.etag),
        ne(sessions.visibility, "private"),
        isNull(sessions.windJson),
        eq(sessions.publicZonesVersion, version),
        zonesStillAt(msg.userId, version),
      ),
    );
  return outcome === "processed" ? "processed" : "wind_only";
}

/** Whether a processed session still needs wind: others can see it and it has none. */
export const needsWind = (s: Pick<Session, "visibility" | "windJson" | "publicMinLat">) =>
  s.visibility !== "private" && s.windJson === null && s.publicMinLat !== null;

/**
 * Re-reads the row right before calling Open-Meteo, so a session made private (or whose
 * data was replaced) since the snapshot causes no request. Null when none is made.
 */
async function lookupWind(
  db: Db,
  snapshot: Session,
  current: SQL | undefined,
  deps: ProcessDeps,
): Promise<StoredWind | null> {
  await deps.hooks?.beforeWind?.();
  const [session] = await db.select().from(sessions).where(current);
  if (
    !session ||
    !needsWind(session) ||
    session.processedEtag !== snapshot.processedEtag ||
    session.publicZonesVersion !== snapshot.publicZonesVersion
  ) {
    return null;
  }
  const now = deps.now?.() ?? Date.now();
  // Only what others may see: the public box and the public time range.
  const startedAt = session.publicTrackStartedAt;
  const endedAt = session.publicTrackEndedAt ?? startedAt;
  if (startedAt === null || endedAt === null) return null;
  const center = boundsCenter({
    south: session.publicMinLat as number,
    west: session.publicMinLon as number,
    north: session.publicMaxLat as number,
    east: session.publicMaxLon as number,
  });
  const url = windRequest(center, { startedAt, endedAt }, now);
  if (!url) return { status: "unavailable", reason: "no_window", fetchedAt: now };
  return fetchWind(url, { startedAt, endedAt }, deps.fetch ?? fetch, now);
}

/** The user's sessions with a track whose public data is behind their zones version. */
export async function staleSessions(
  db: Db,
  userId: string,
  after: string | undefined,
  limit: number,
) {
  return db
    .select({ id: sessions.id, revision: sessions.uploadRevision, etag: sessions.trackEtag })
    .from(sessions)
    .innerJoin(users, eq(users.id, sessions.userId))
    .where(
      and(
        eq(sessions.userId, userId),
        isNull(sessions.deletedAt),
        isNotNull(sessions.trackKey),
        isNotNull(sessions.trackEtag),
        or(
          isNull(sessions.publicZonesVersion),
          ne(sessions.publicZonesVersion, users.zonesVersion),
        ),
        after === undefined ? undefined : gt(sessions.id, after),
      ),
    )
    .orderBy(asc(sessions.id))
    .limit(limit);
}

const sessionMessage = (
  userId: string,
  row: { id: string; revision: number; etag: string | null },
): SessionMessage => ({
  v: 1,
  sessionId: row.id,
  userId,
  revision: row.revision,
  etag: row.etag as string,
});

/**
 * A `user` message: queues a page of the user's sessions that are behind, then a
 * follow-up for the rest. Idempotent: a redelivery queues the same sessions again, which
 * ignore it once done. Throws (so the message retries) when a send fails.
 */
async function requeueUser(env: ProcessEnv, msg: UserMessage): Promise<void> {
  const queue = env.POSTPROCESS;
  if (!queue) throw new RetryLater("a user message needs the queue");
  const page = await staleSessions(drizzle(env.DB), msg.userId, msg.after, USER_PAGE);
  if (page.length > 0) {
    await queue.sendBatch(page.map((row) => ({ body: sessionMessage(msg.userId, row) })));
  }
  const last = page.at(-1);
  if (page.length === USER_PAGE && last) {
    await queue.send({ v: 1, kind: "user", userId: msg.userId, after: last.id });
  }
}

/** Queue handler: ack what is done or will never succeed, retry the rest with backoff. */
export async function handlePostprocessBatch(
  batch: MessageBatch<unknown>,
  env: Env,
  deps: ProcessDeps = {},
): Promise<void> {
  for (const message of batch.messages) {
    try {
      const outcome = await processMessage(env, message.body, deps);
      if (outcome === "invalid_message") {
        console.warn("Dropping a malformed post-processing message.");
      }
      message.ack();
    } catch (error) {
      if (!(error instanceof RetryLater || error instanceof WindTransientError)) {
        console.error("Post-processing failed; retrying.", error);
      }
      message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
    }
  }
}

/**
 * Sends messages to the POSTPROCESS queue. Throws when the queue rejects a send.
 *
 * Without the binding (previews, or a self-hosted copy without Queues) it processes them
 * after the response with waitUntil instead: one attempt, no retries, and a `user`
 * message covers at most INLINE_USER_LIMIT sessions, since a waitUntil gets about 30 s.
 * The others show no public data until their next upload or zone change.
 */
export async function enqueuePostprocess(
  env: ProcessEnv,
  ctx: Pick<ExecutionContext, "waitUntil">,
  messages: PostprocessMessage[],
): Promise<void> {
  if (messages.length === 0) return;
  const queue = env.POSTPROCESS;
  if (!queue) {
    ctx.waitUntil(processInline(env, messages));
    return;
  }
  for (let i = 0; i < messages.length; i += 100) {
    await queue.sendBatch(messages.slice(i, i + 100).map((body) => ({ body })));
  }
}

export async function processInline(env: ProcessEnv, messages: PostprocessMessage[]) {
  const db = drizzle(env.DB);
  for (const message of messages) {
    try {
      if (message.kind === "user") {
        const page = await staleSessions(db, message.userId, undefined, INLINE_USER_LIMIT);
        for (const row of page) await processSession(env, sessionMessage(message.userId, row));
      } else {
        await processSession(env, message);
      }
    } catch (error) {
      console.warn("Inline post-processing failed.", error);
    }
  }
}

/**
 * Queues the user's reprocessing if a zone change has not been queued yet
 * (users.zones_queued_version behind zones_version), then records it. Throws when the
 * send fails, leaving the marker for the next zone change, upload or sweep.
 */
export async function ensureUserRequeued(
  env: ProcessEnv,
  ctx: Pick<ExecutionContext, "waitUntil">,
  userId: string,
): Promise<boolean> {
  const db = drizzle(env.DB);
  const [user] = await db
    .select({ version: users.zonesVersion, queued: users.zonesQueuedVersion })
    .from(users)
    .where(eq(users.id, userId));
  if (!user || user.queued >= user.version) return false;
  await enqueuePostprocess(env, ctx, [{ v: 1, kind: "user", userId }]);
  // Only forward: a later zone change keeps the marker behind its own version.
  await db
    .update(users)
    .set({ zonesQueuedVersion: user.version })
    .where(and(eq(users.id, userId), lt(users.zonesQueuedVersion, user.version)));
  return true;
}

/** Users the scheduled sweep handles per run. */
export const SWEEP_USERS = 100;

/** Scheduled sweep: queues reprocessing for users whose zone change was never queued. */
export async function sweepPendingZoneChanges(
  env: ProcessEnv,
  ctx: Pick<ExecutionContext, "waitUntil">,
): Promise<number> {
  const pending = await drizzle(env.DB)
    .select({ id: users.id })
    .from(users)
    .where(lt(users.zonesQueuedVersion, users.zonesVersion))
    .limit(SWEEP_USERS);
  let queued = 0;
  for (const { id } of pending) {
    try {
      if (await ensureUserRequeued(env, ctx, id)) queued += 1;
    } catch (error) {
      console.warn("Could not queue a pending zone change; the next sweep retries.", error);
    }
  }
  return queued;
}
