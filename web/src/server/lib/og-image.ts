import {
  and,
  eq,
  exists,
  gt,
  isNotNull,
  isNull,
  lte,
  ne,
  notExists,
  or,
  type SQL,
  sql,
} from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { pendingR2Deletes, privacyZones, type Session, sessions, users } from "../db/schema";
import { projectRoute, routeCardAlt, routeCardSvg, routeRuns, type Units } from "../og/card";
import { svgToPng } from "../og/render";
import { discardKey, UPLOAD_GRACE_MS } from "./r2-garbage";
import { arcClearsZones, PRIVACY_GAP_EVENT, shareTrack, type Zone } from "./session-privacy";
import { userPrefix } from "./storage";
import { parseGzippedJson, TrackTooLarge } from "./track";

// Open Graph route images for shared sessions (docs/PLAN.md §7). One PNG per session in
// the TRACKS bucket, under the session's own prefix, so deleting the session or the
// account deletes it with the track.
//
// Privacy: the image is drawn from the shared copy of the track (shareTrack), never the
// stored file, so it shows nothing GET /api/sessions/{id}/track does not show to anyone:
// no fix inside a privacy zone and no line across one. It exists only for sessions others
// may see whose public data is at the owner's current zones version. The object carries a
// fingerprint of everything drawn (track ETag, zones version, sport, distance, duration,
// units, renderer version) and is served only while that still matches the session, so a
// new zone, a trimmed track (a new upload) or a units change cannot serve an old image.
// A cache miss serves the brand fallback and schedules an image refresh.

/** Bump when the card's design or route projection changes. */
export const OG_RENDER_VERSION = 2;

export const ogImageKey = (userId: string, sessionId: string) =>
  `${userPrefix(userId)}sessions/${sessionId}/og.png`;

/** Record even an attached card before deleting its session. An in-flight reservation
 * already records the same key and keeps its original grace period. */
export function recordSessionOgKeys(
  d1: D1Database,
  where: string,
  binds: unknown[],
  now = Date.now(),
): D1PreparedStatement {
  return d1
    .prepare(
      `INSERT OR IGNORE INTO pending_r2_deletes (key, user_id, created_at)
       SELECT 'users/' || user_id || '/sessions/' || id || '/og.png', user_id, ?
       FROM sessions WHERE (${where})`,
    )
    .bind(now - UPLOAD_GRACE_MS - 1, ...binds);
}

type OgSession = Pick<
  Session,
  | "id"
  | "userId"
  | "sport"
  | "visibility"
  | "distanceM"
  | "durationS"
  | "trackKey"
  | "trackEtag"
  | "processedEtag"
  | "postprocessStatus"
  | "publicZonesVersion"
  | "publicMinLat"
>;

/** Whether others may see a route image for this session, given the owner's zones version. */
export const ogEligible = (s: OgSession, zonesVersion: number | null | undefined): boolean =>
  s.visibility !== "private" &&
  s.trackKey !== null &&
  s.trackEtag !== null &&
  s.processedEtag === s.trackEtag &&
  s.postprocessStatus === "done" &&
  zonesVersion != null &&
  s.publicZonesVersion === zonesVersion &&
  // No fix others may see: nothing to draw.
  s.publicMinLat !== null;

/** A short hash of everything the image shows; also its HTTP ETag and URL version. */
export async function ogFingerprint(
  s: OgSession,
  units: Units,
  zonesVersion: number,
): Promise<string> {
  const input = JSON.stringify([
    OG_RENDER_VERSION,
    s.trackEtag,
    zonesVersion,
    s.sport,
    s.distanceM,
    s.durationS,
    units,
  ]);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest).slice(0, 8), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}

export type OgInfo = { fingerprint: string; alt: string };

/** The current image's fingerprint and alt text, or null when the session gets none. */
export async function ogInfo(
  s: OgSession,
  units: Units,
  zonesVersion: number | null | undefined,
): Promise<OgInfo | null> {
  if (!ogEligible(s, zonesVersion) || zonesVersion == null) return null;
  return {
    fingerprint: await ogFingerprint(s, units, zonesVersion),
    alt: routeCardAlt({
      sport: s.sport,
      units,
      distanceM: s.distanceM,
      durationS: s.durationS,
    }),
  };
}

type Db = ReturnType<typeof drizzle>;
type OgEnv = Pick<Env, "DB" | "TRACKS">;

function activeSession(db: Db, sessionId: string, condition?: SQL) {
  return db
    .select({
      session: {
        id: sessions.id,
        userId: sessions.userId,
        sport: sessions.sport,
        visibility: sessions.visibility,
        distanceM: sessions.distanceM,
        durationS: sessions.durationS,
        trackKey: sessions.trackKey,
        trackEtag: sessions.trackEtag,
        processedEtag: sessions.processedEtag,
        postprocessStatus: sessions.postprocessStatus,
        publicZonesVersion: sessions.publicZonesVersion,
        publicMinLat: sessions.publicMinLat,
      },
      units: users.units,
      zonesVersion: users.zonesVersion,
    })
    .from(sessions)
    .innerJoin(users, and(eq(users.id, sessions.userId), isNull(users.deletedAt)))
    .where(and(eq(sessions.id, sessionId), isNull(sessions.deletedAt), condition));
}

type OgState = Awaited<ReturnType<typeof activeSession>>[number];

/** Match the content fingerprint inputs and sharing eligibility in a single D1 snapshot. */
function currentSession(db: Db, { session, units, zonesVersion }: OgState, condition?: SQL) {
  return activeSession(
    db,
    session.id,
    and(
      eq(sessions.userId, session.userId),
      ne(sessions.visibility, "private"),
      sql`${sessions.trackKey} IS ${session.trackKey}`,
      sql`${sessions.trackEtag} IS ${session.trackEtag}`,
      eq(sessions.processedEtag, sessions.trackEtag),
      eq(sessions.postprocessStatus, "done"),
      eq(sessions.publicZonesVersion, zonesVersion),
      isNotNull(sessions.publicMinLat),
      eq(users.zonesVersion, zonesVersion),
      eq(users.units, units),
      eq(sessions.sport, session.sport),
      sql`${sessions.distanceM} IS ${session.distanceM}`,
      sql`${sessions.durationS} IS ${session.durationS}`,
      condition,
    ),
  );
}

const OG_MAX_INFLATED_BYTES = 2 * 1024 * 1024;
const OG_MAX_INPUT_FIXES = 20_000;

/** Keep a cold miss from sending another message while this fingerprint is queued or
 * the session has a producer. A lost message or cancelled request can be retried later. */
async function enqueueRefresh(
  db: Db,
  state: OgState,
  key: string,
  fingerprint: string,
  send: () => Promise<unknown>,
) {
  const now = Date.now();
  const running = db
    .select({ key: pendingR2Deletes.key })
    .from(pendingR2Deletes)
    .where(
      and(eq(pendingR2Deletes.key, key), gt(pendingR2Deletes.createdAt, now - UPLOAD_GRACE_MS)),
    );
  const marker = and(eq(sessions.ogQueuedFingerprint, fingerprint), eq(sessions.ogQueuedAt, now));
  const reserved = await db
    .update(sessions)
    .set({ ogQueuedFingerprint: fingerprint, ogQueuedAt: now })
    .where(
      and(
        eq(sessions.id, state.session.id),
        exists(currentSession(db, state)),
        notExists(running),
        or(
          sql`${sessions.ogQueuedFingerprint} IS NOT ${fingerprint}`,
          lte(sessions.ogQueuedAt, now - UPLOAD_GRACE_MS),
        ),
      ),
    );
  if (reserved.meta.changes !== 1) return;
  try {
    await send();
  } catch (error) {
    await db
      .update(sessions)
      .set({ ogQueuedFingerprint: null, ogQueuedAt: null })
      .where(and(eq(sessions.id, state.session.id), marker));
    throw error;
  }
}

/** Draws the route card from the shared copy of the track, or null if it cannot be read. */
async function render(bucket: R2Bucket, state: OgState, zones: Zone[]): Promise<Uint8Array | null> {
  const { session } = state;
  if (!session.trackKey) return null;
  const object = await bucket.get(session.trackKey);
  if (!object || object.etag !== session.trackEtag) {
    await object?.body.cancel();
    throw new Error("The route image's source track changed before rendering.");
  }
  const shared = await parseGzippedJson(object.body, OG_MAX_INFLATED_BYTES)
    .then((track) => shareTrack(track, zones, null, OG_MAX_INPUT_FIXES))
    .catch((error: unknown) => {
      if (error instanceof TrackTooLarge) return null;
      throw error;
    });
  if (!shared) return null;
  const gps = shared.gps as { lat: number[]; lon: number[] };
  const gaps = (shared.events as { type: string; data?: { index?: number } }[])
    .filter((e) => e.type === PRIVACY_GAP_EVENT && typeof e.data?.index === "number")
    .map((e) => e.data?.index as number);
  const route = projectRoute(
    routeRuns(gps.lat, gps.lon, gaps),
    undefined,
    zones.length === 0 ? undefined : (a, b) => arcClearsZones(a, b, zones),
  );
  if (!route.start) return null;
  return svgToPng(
    routeCardSvg({
      sport: session.sport,
      units: state.units,
      distanceM: session.distanceM,
      durationS: session.durationS,
      route,
    }),
  );
}

/** `body` is null when the caller's ETag matched and the stored image was current. */
export type OgImage = { fingerprint: string; body: ReadableStream | null };

export async function ogImage(
  env: OgEnv,
  sessionId: string,
  options: {
    ifNoneMatch?: string;
    enqueueOnMiss?: () => Promise<unknown>;
    waitUntil?: (work: Promise<unknown>) => void;
  } = {},
): Promise<OgImage | null> {
  const db = drizzle(env.DB);
  const [state] = await activeSession(db, sessionId);
  if (!state || !ogEligible(state.session, state.zonesVersion)) return null;
  const fingerprint = await ogFingerprint(state.session, state.units, state.zonesVersion);
  const key = ogImageKey(state.session.userId, sessionId);
  const conditional = options.ifNoneMatch === `"${fingerprint}"`;
  const stored = conditional ? await env.TRACKS.head(key) : await env.TRACKS.get(key);
  const body = stored && "body" in stored ? (stored as R2ObjectBody).body : null;
  const matches = stored?.customMetadata?.fp === fingerprint;
  if (!matches || stored?.size === 0) {
    await body?.cancel();
    if (!matches) {
      if (options.enqueueOnMiss) {
        await enqueueRefresh(db, state, key, fingerprint, options.enqueueOnMiss);
      } else {
        options.waitUntil?.(
          syncOgImage(env, sessionId).catch((error: unknown) =>
            console.warn("Could not update the route image.", error),
          ),
        );
      }
    }
    return null;
  }

  // Last I/O before serving either a body or a 304. The R2 read may have overlapped a
  // privacy edit, trim or deletion. Conditional requests use HEAD so no body needs
  // cancelling after this check.
  let current = false;
  try {
    current = (await currentSession(db, state)).length > 0;
    return current ? { fingerprint, body } : null;
  } finally {
    if (!current) await body?.cancel();
  }
}

/**
 * One producer at a time per session, even across isolates. The ledger covers a put
 * until the card is attached. Its grace period also acts as a lease, so a cancelled
 * producer can be replaced without waiting for the collector.
 */
export async function syncOgImage(
  env: OgEnv,
  sessionId: string,
): Promise<"current" | "deleted" | "none"> {
  const db = drizzle(env.DB);
  const [initial] = await activeSession(db, sessionId);
  if (!initial) return "none";
  const { userId } = initial.session;
  const key = ogImageKey(userId, sessionId);

  const fingerprint = ogEligible(initial.session, initial.zonesVersion)
    ? await ogFingerprint(initial.session, initial.units, initial.zonesVersion)
    : null;
  const stored = await env.TRACKS.head(key);
  if (fingerprint && stored?.customMetadata?.fp === fingerprint) return "current";
  if (!fingerprint && !stored) return "none";

  const createdAt = Date.now();
  const before = createdAt - UPLOAD_GRACE_MS;
  const reserve = async () =>
    (
      await db
        .insert(pendingR2Deletes)
        .values({ key, userId, createdAt })
        .onConflictDoUpdate({
          target: pendingR2Deletes.key,
          set: { createdAt },
          setWhere: and(isNull(pendingR2Deletes.claim), lte(pendingR2Deletes.createdAt, before)),
        })
    ).meta.changes === 1;
  if (!(await reserve())) {
    // Finish an expired cleanup claim before trying again. This also works without cron.
    if (!(await discardKey(db, env.TRACKS, key, { before })) || !(await reserve())) return "none";
  }
  const reservation = and(
    eq(pendingR2Deletes.key, key),
    eq(pendingR2Deletes.createdAt, createdAt),
    isNull(pendingR2Deletes.claim),
  );
  const held = db.select({ key: pendingR2Deletes.key }).from(pendingR2Deletes).where(reservation);
  const discard = async () => {
    await discardKey(db, env.TRACKS, key, { before: createdAt });
    return "deleted" as const;
  };

  try {
    // A producer may have finished since our first HEAD, or the session may have changed.
    const [[state], zones] = await db.batch([
      activeSession(db, sessionId, eq(sessions.userId, userId)),
      db
        .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
        .from(privacyZones)
        .where(eq(privacyZones.userId, userId)),
    ]);
    if (!state || !ogEligible(state.session, state.zonesVersion)) return await discard();
    const fp = await ogFingerprint(state.session, state.units, state.zonesVersion);
    const current = currentSession(db, state);
    const existing = await env.TRACKS.head(key);
    if (existing?.customMetadata?.fp !== fp) {
      const png = await render(env.TRACKS, state, zones);
      const stillHeld = currentSession(db, state, exists(held));
      if ((await stillHeld).length === 0) return await discard();

      // Random bytes with no route data give this attempt a unique ETag.
      // The final put can only replace that payload. If a delete, collector or newer
      // producer removes it before a delayed put commits, R2 refuses the late PNG.
      const fence = await env.TRACKS.put(key, crypto.randomUUID(), {
        onlyIf: existing ? { etagMatches: existing.etag } : { etagDoesNotMatch: "*" },
      });
      if (!fence || (await stillHeld).length === 0) return await discard();
      // A zero-byte marker remembers routes that exceeded the image budget.
      const written = await env.TRACKS.put(key, png ?? new Uint8Array(), {
        onlyIf: { etagMatches: fence.etag },
        httpMetadata: png ? { contentType: "image/png" } : undefined,
        customMetadata: { fp },
      });
      if (!written) return await discard();
    }

    // Consume the ledger entry atomically with the eligibility/fingerprint check.
    const committed = await db.delete(pendingR2Deletes).where(and(reservation, exists(current)));
    return committed.meta.changes === 1 ? "current" : await discard();
  } catch (error) {
    // Keep the durable cleanup record even when R2 may have accepted the write.
    // Expiring this attempt lets a queue redelivery or later GET claim it immediately.
    await db.update(pendingR2Deletes).set({ createdAt: 0 }).where(reservation);
    throw error;
  }
}
