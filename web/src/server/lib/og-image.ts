import { and, eq, exists, isNotNull, isNull, ne, type SQL, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { pendingR2Deletes, privacyZones, type Session, sessions, users } from "../db/schema";
import { projectRoute, routeCardAlt, routeCardSvg, routeRuns, type Units } from "../og/card";
import { svgToPng } from "../og/render";
import { discardKey, recordKey } from "./r2-garbage";
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
// A cache miss serves the brand fallback and asks the queue to refresh the route image.

/** Bump when the card's design or route projection changes. */
export const OG_RENDER_VERSION = 2;

export const ogImageKey = (userId: string, sessionId: string) =>
  `${userPrefix(userId)}sessions/${sessionId}/og.png`;

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
  options: { ifNoneMatch?: string; onMiss?: () => Promise<void> } = {},
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
    if (!matches) await options.onMiss?.();
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
 * One producer at a time per session, even across isolates. The record doubles as a
 * reservation and survives a failed or late R2 write. The collector honors the same
 * grace period as track uploads, then retries failed deletes. A successful write
 * releases its reservation only while the session still matches the card we drew.
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
  const reserved = await recordKey(env.DB, key, userId, createdAt).run();
  if (reserved.meta.changes !== 1) return "none";
  const reservation = and(
    eq(pendingR2Deletes.key, key),
    eq(pendingR2Deletes.createdAt, createdAt),
    isNull(pendingR2Deletes.claim),
  );

  // Read the zones and the session together after taking the reservation. A producer
  // may have finished since our first HEAD, or the session may have changed.
  const [[state], zones] = await db.batch([
    activeSession(db, sessionId, eq(sessions.userId, userId)),
    db
      .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
      .from(privacyZones)
      .where(eq(privacyZones.userId, userId)),
  ]);
  if (!state || !ogEligible(state.session, state.zonesVersion)) {
    await discardKey(db, env.TRACKS, key, { before: createdAt });
    return "deleted";
  }
  const fp = await ogFingerprint(state.session, state.units, state.zonesVersion);
  if ((await env.TRACKS.head(key))?.customMetadata?.fp === fp) {
    await db.delete(pendingR2Deletes).where(reservation);
    return "current";
  }

  const png = await render(env.TRACKS, state, zones);
  const held = db.select({ key: pendingR2Deletes.key }).from(pendingR2Deletes).where(reservation);
  if ((await currentSession(db, state, exists(held))).length === 0) {
    await discardKey(db, env.TRACKS, key, { before: createdAt });
    return "deleted";
  }
  // A zero-byte marker remembers routes that exceeded the image budget. It has the
  // same lifetime as a card, and a changed fingerprint allows another attempt.
  await env.TRACKS.put(key, png ?? new Uint8Array(), {
    httpMetadata: png ? { contentType: "image/png" } : undefined,
    customMetadata: { fp },
  });

  // Consume the ledger entry atomically with the D1 eligibility/fingerprint check.
  // If deletion already swept the prefix, this leaves the late write collectable
  // even when the following immediate cleanup fails.
  const committed = await db
    .delete(pendingR2Deletes)
    .where(and(reservation, exists(currentSession(db, state))));
  if (committed.meta.changes === 1) return "current";
  await discardKey(db, env.TRACKS, key, { before: createdAt });
  return "deleted";
}
