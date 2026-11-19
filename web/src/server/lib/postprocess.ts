import { z } from "@hono/zod-openapi";
import { and, eq, isNotNull, isNull } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { privacyZones, type Session, sessions } from "../db/schema";
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
// Memory: the track is inflated as a stream with the shared-track caps from #64
// (SHARED_TRACK_MAX_INFLATED_BYTES, SHARED_TRACK_MAX_FIXES). A larger track is marked
// `too_large` and gets no derived data, as it gets no shared copy.

export const PostprocessMessage = z.object({
  v: z.literal(1),
  sessionId: z.string().uuid(),
  userId: z.string().min(1),
  revision: z.number().int().min(0),
  etag: z.string().min(1),
});
export type PostprocessMessage = z.infer<typeof PostprocessMessage>;

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
  publicMinLat: null,
  publicMinLon: null,
  publicMaxLat: null,
  publicMaxLon: null,
  windJson: null,
} as const;

/**
 * What a privacy zone change clears: the public bounds and the processed marker, so the
 * session is processed again with the new zones. Wind stays: it is not positional data
 * others could not already see, and refetching it for every session on each zone edit
 * would send Open-Meteo many requests for nothing.
 */
export const CLEARED_PUBLIC = {
  processedEtag: null,
  postprocessStatus: null,
  publicMinLat: null,
  publicMinLon: null,
  publicMaxLat: null,
  publicMaxLon: null,
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
  | "invalid_message";

export class RetryLater extends Error {}

async function loadZones(db: Db, userId: string): Promise<Zone[]> {
  return db
    .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
    .from(privacyZones)
    .where(eq(privacyZones.userId, userId))
    .orderBy(privacyZones.id);
}

const zonesKey = (zones: Zone[]) => JSON.stringify(zones.map((z) => [z.lat, z.lon, z.radiusM]));

/** Whether a processed session still needs wind: others can see it and it has none. */
export const needsWind = (s: Pick<Session, "visibility" | "windJson" | "publicMinLat">) =>
  s.visibility !== "private" && s.windJson === null && s.publicMinLat !== null;

export type ProcessDeps = { fetch?: typeof fetch; now?: () => number };

/**
 * Processes one message. Returns the outcome, or throws when the message should be
 * retried (RetryLater, WindTransientError, or any D1/R2 failure).
 */
export async function processSession(
  env: Pick<Env, "DB" | "TRACKS">,
  raw: unknown,
  deps: ProcessDeps = {},
): Promise<Outcome> {
  const parsed = PostprocessMessage.safeParse(raw);
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
  const [row] = await db.select().from(sessions).where(current);
  if (!row) return "skipped_stale";

  let session = row;
  let outcome: Outcome = "skipped_done";
  if (row.processedEtag !== msg.etag) {
    const object = await env.TRACKS.get(key);
    // Replaced or deleted since; the newer upload has its own message.
    if (!object || object.etag !== msg.etag) {
      await object?.body.cancel();
      return "skipped_stale";
    }
    const zones = await loadZones(db, msg.userId);
    let derived: TrackDerived | null = null;
    let status: "done" | "too_large" | "invalid" = "done";
    try {
      derived = deriveTrack(
        await parseGzippedJson(object.body, SHARED_TRACK_MAX_INFLATED_BYTES),
        msg.sessionId,
        zones,
      );
    } catch (error) {
      if (error instanceof TrackTooLarge) status = "too_large";
      else if (error instanceof InvalidTrack || error instanceof SyntaxError) status = "invalid";
      else if (error instanceof TypeError)
        status = "invalid"; // corrupt gzip data
      else throw error;
    }
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
      })
      .where(current)
      .returning();
    if (!written) return "skipped_stale";
    // A zone added while this ran may not be in `zones`. Its route clears the public
    // bounds after inserting it, so only a change before this re-read can be missed:
    // clear what was written and try again.
    if (zonesKey(await loadZones(db, msg.userId)) !== zonesKey(zones)) {
      await db.update(sessions).set(CLEARED_PUBLIC).where(current);
      throw new RetryLater("privacy zones changed while processing");
    }
    if (status !== "done") return status;
    session = written;
    outcome = "processed";
  }

  if (!needsWind(session)) return outcome;
  const wind = await lookupWind(session, deps);
  // Only while the row is still processed from this track and still has no wind.
  await db
    .update(sessions)
    .set({ windJson: JSON.stringify(wind) })
    .where(and(current, eq(sessions.processedEtag, msg.etag), isNull(sessions.windJson)));
  return outcome === "processed" ? "processed" : "wind_only";
}

async function lookupWind(session: Session, deps: ProcessDeps): Promise<StoredWind> {
  const now = deps.now?.() ?? Date.now();
  const startedAt = session.trackStartedAt ?? session.startedAt;
  const endedAt = session.trackEndedAt ?? session.endedAt ?? startedAt;
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

/** Queue handler: ack what is done or will never succeed, retry the rest with backoff. */
export async function handlePostprocessBatch(
  batch: MessageBatch<unknown>,
  env: Env,
  deps: ProcessDeps = {},
): Promise<void> {
  for (const message of batch.messages) {
    try {
      const outcome = await processSession(env, message.body, deps);
      if (outcome === "invalid_message")
        console.warn("Dropping a malformed post-processing message.");
      message.ack();
    } catch (error) {
      if (!(error instanceof RetryLater || error instanceof WindTransientError)) {
        console.error("Post-processing failed; retrying.", error);
      }
      message.retry({ delaySeconds: retryDelaySeconds(message.attempts) });
    }
  }
}

type PostprocessEnv = Pick<Env, "DB" | "TRACKS"> & { POSTPROCESS?: Queue<PostprocessMessage> };

/**
 * Sends messages to the POSTPROCESS queue. Without the binding (previews, or a self-hosted
 * copy without Queues) it processes them after the response with waitUntil instead: one
 * attempt, no retries. Throws when the queue rejects a send.
 */
export async function enqueuePostprocess(
  env: PostprocessEnv,
  ctx: Pick<ExecutionContext, "waitUntil">,
  messages: PostprocessMessage[],
): Promise<void> {
  if (messages.length === 0) return;
  const queue = env.POSTPROCESS;
  if (!queue) {
    ctx.waitUntil(
      (async () => {
        for (const message of messages) {
          await processSession(env, message).catch((error) =>
            console.warn("Inline post-processing failed.", error),
          );
        }
      })(),
    );
    return;
  }
  for (let i = 0; i < messages.length; i += 100) {
    await queue.sendBatch(messages.slice(i, i + 100).map((body) => ({ body })));
  }
}

/**
 * After the user's privacy zones change: clears the public bounds of every session with a
 * track (so none outlives the zones it was cut with) and queues them again.
 */
export async function reprocessUserSessions(
  env: PostprocessEnv,
  ctx: Pick<ExecutionContext, "waitUntil">,
  userId: string,
): Promise<void> {
  const rows = await drizzle(env.DB)
    .update(sessions)
    .set(CLEARED_PUBLIC)
    .where(
      and(
        eq(sessions.userId, userId),
        isNull(sessions.deletedAt),
        isNotNull(sessions.trackKey),
        isNotNull(sessions.trackEtag),
      ),
    )
    .returning({ id: sessions.id, revision: sessions.uploadRevision, etag: sessions.trackEtag });
  // A failed send leaves those sessions pending without public bounds: nothing is shown
  // that the new zones would hide, and their next upload or zone change queues them again.
  await enqueuePostprocess(
    env,
    ctx,
    rows.map((r) => ({
      v: 1,
      sessionId: r.id,
      userId,
      revision: r.revision,
      etag: r.etag as string,
    })),
  ).catch((error) => console.error("Could not queue reprocessing after a zone change.", error));
}
