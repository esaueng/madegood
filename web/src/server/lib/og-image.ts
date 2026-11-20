import { and, eq, isNull, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { privacyZones, type Session, sessions, users } from "../db/schema";
import { projectRoute, routeCardAlt, routeCardSvg, routeRuns, type Units } from "../og/card";
import { svgToPng } from "../og/render";
import { PRIVACY_GAP_EVENT, shareTrack, type Zone } from "./session-privacy";
import { userPrefix } from "./storage";
import { parseGzippedJson, SHARED_TRACK_MAX_INFLATED_BYTES } from "./track";

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
// new zone, a trimmed track (a new upload) or a units change is never shown from an old
// image; post-processing redraws it, or the first request does. A session made private, or
// one that can no longer have an image, has its object deleted (syncOgImage); the route
// checks visibility on every request regardless.

/** Bump when the card's design changes, so stored images are redrawn. */
export const OG_RENDER_VERSION = 1;

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

type OgState = { session: Session; units: Units; zonesVersion: number; zones: Zone[] };

/**
 * The session (live, owner active), the owner's units and zones version, and their zones,
 * read in one D1 batch so the zones are the ones that version names.
 */
async function loadState(db: D1Database, sessionId: string): Promise<OgState | null> {
  const orm = drizzle(db);
  const [rows, zones] = await orm.batch([
    orm
      .select({ session: sessions, units: users.units, zonesVersion: users.zonesVersion })
      .from(sessions)
      .innerJoin(users, and(eq(users.id, sessions.userId), isNull(users.deletedAt)))
      .where(and(eq(sessions.id, sessionId), isNull(sessions.deletedAt))),
    orm
      .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
      .from(privacyZones)
      .where(
        eq(
          privacyZones.userId,
          sql`(SELECT ${sessions.userId} FROM ${sessions} WHERE ${sessions.id} = ${sessionId})`,
        ),
      ),
  ]);
  const row = rows[0];
  return row ? { ...row, zones } : null;
}

/** Draws the route card from the shared copy of the track, or null if it cannot be read. */
async function render(bucket: R2Bucket, state: OgState): Promise<Uint8Array | null> {
  const { session } = state;
  if (!session.trackKey) return null;
  const object = await bucket.get(session.trackKey);
  if (!object || object.etag !== session.trackEtag) {
    await object?.body.cancel();
    return null;
  }
  const shared = shareTrack(
    await parseGzippedJson(object.body, SHARED_TRACK_MAX_INFLATED_BYTES),
    state.zones,
    null,
  );
  if (!shared) return null;
  const gps = shared.gps as { lat: number[]; lon: number[] };
  const gaps = (shared.events as { type: string; data?: { index?: number } }[])
    .filter((e) => e.type === PRIVACY_GAP_EVENT && typeof e.data?.index === "number")
    .map((e) => e.data?.index as number);
  const route = projectRoute(routeRuns(gps.lat, gps.lon, gaps));
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

/** `body` is null when the caller asked for none and the stored image was current. */
export type OgImage = { fingerprint: string; body: ReadableStream | Uint8Array | null };

/**
 * The session's current route image: the stored one while its fingerprint matches, else
 * drawn now and stored. Null when the session gets no image (private, deleted, not
 * processed, public data behind the zones, nothing visible).
 */
export async function ogImage(
  env: Pick<Env, "DB" | "TRACKS">,
  sessionId: string,
  options: { body?: boolean } = {},
): Promise<OgImage | null> {
  const state = await loadState(env.DB, sessionId);
  if (!state || !ogEligible(state.session, state.zonesVersion)) return null;
  const fingerprint = await ogFingerprint(state.session, state.units, state.zonesVersion);
  const key = ogImageKey(state.session.userId, sessionId);

  const stored = options.body === false ? await env.TRACKS.head(key) : await env.TRACKS.get(key);
  const storedBody = stored && "body" in stored ? (stored as R2ObjectBody).body : null;
  if (stored?.customMetadata?.fp === fingerprint) return { fingerprint, body: storedBody };
  await storedBody?.cancel();

  const png = await render(env.TRACKS, state);
  if (!png) return null;
  await env.TRACKS.put(key, png, {
    httpMetadata: { contentType: "image/png" },
    customMetadata: { fp: fingerprint },
  });
  // Deleted while drawing: the session's prefix was already cleared, so remove this too.
  const [still] = await drizzle(env.DB)
    .select({ id: sessions.id })
    .from(sessions)
    .where(and(eq(sessions.id, sessionId), isNull(sessions.deletedAt)));
  if (!still) {
    await env.TRACKS.delete(key);
    return null;
  }
  return { fingerprint, body: png };
}

/**
 * Brings the stored image in line with the session: drawn when it should have one and the
 * stored one is out of date, deleted when it should have none. Post-processing and
 * visibility changes call it; failures are left to the next call or the first request.
 */
export async function syncOgImage(
  env: Pick<Env, "DB" | "TRACKS">,
  sessionId: string,
): Promise<"current" | "deleted" | "none"> {
  const image = await ogImage(env, sessionId, { body: false });
  if (image) return "current";
  const [row] = await drizzle(env.DB)
    .select({ userId: sessions.userId })
    .from(sessions)
    .where(eq(sessions.id, sessionId));
  if (!row) return "none";
  await env.TRACKS.delete(ogImageKey(row.userId, sessionId));
  return "deleted";
}
