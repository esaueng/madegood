import { and, eq, inArray, isNotNull, isNull, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { privacyZones, type Session, sessions, users } from "../db/schema";
import { projectRoute, routeCardAlt, routeCardSvg, routeRuns, type Units } from "../og/card";
import { svgToPng } from "../og/render";
import { arcClearsZones, PRIVACY_GAP_EVENT, shareTrack, type Zone } from "./session-privacy";
import { parseGzippedJson, TrackTooLarge } from "./track";

// Open Graph route images for shared sessions (docs/PLAN.md §7). The Worker renders
// from the same privacy-filtered track as the public API and checks D1 before looking
// in the edge cache and again after reading or rendering a card.

/** Bump when the card's design or route projection changes. */
export const OG_RENDER_VERSION = 2;

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
  (s.visibility === "public" || s.visibility === "unlisted") &&
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

function activeSession(db: Db, sessionId: string) {
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
    .where(and(eq(sessions.id, sessionId), isNull(sessions.deletedAt)));
}

type OgState = Awaited<ReturnType<typeof activeSession>>[number];

/** Match the original render inputs and sharing eligibility in a single D1 snapshot. */
function currentSession(db: Db, { session, units, zonesVersion }: OgState) {
  return db
    .select({ id: sessions.id })
    .from(sessions)
    .innerJoin(users, and(eq(users.id, sessions.userId), isNull(users.deletedAt)))
    .where(
      and(
        eq(sessions.id, session.id),
        isNull(sessions.deletedAt),
        eq(sessions.userId, session.userId),
        inArray(sessions.visibility, ["public", "unlisted"]),
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
      ),
    );
}

const OG_MAX_INFLATED_BYTES = 2 * 1024 * 1024;
const OG_MAX_INPUT_FIXES = 20_000;

// Five minutes covers the usual unfurl burst and limits how long obsolete bytes linger.
const OG_EDGE_TTL_SECONDS = 300;

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

export async function ogImage(
  env: OgEnv,
  sessionId: string,
  request: Request,
  waitUntil: (work: Promise<unknown>) => void,
): Promise<Response | null> {
  const db = drizzle(env.DB);
  const [state] = await activeSession(db, sessionId);
  if (!state || !ogEligible(state.session, state.zonesVersion)) return null;
  const fingerprint = await ogFingerprint(state.session, state.units, state.zonesVersion);
  const url = new URL(request.url);
  if (url.searchParams.get("v") !== fingerprint) return null;

  const etag = `"${fingerprint}"`;
  const validators = request.headers
    .get("if-none-match")
    ?.split(",")
    .map((tag) => tag.trim());
  const conditional = validators?.some((tag) => tag === etag || tag === `W/${etag}` || tag === "*");

  // A canonical GET key keeps cookies, validators, Range and unrelated query parameters
  // out of the Cache API lookup. Only the Worker sees the cache entry's freshness headers.
  const cacheKey = new Request(new URL(`/s/${sessionId}/og.png?v=${fingerprint}`, url));
  const cached = await caches.default.match(cacheKey).catch((error: unknown) => {
    console.warn("Could not read the route image cache.", error);
    return undefined;
  });
  let body = cached?.body ?? null;
  let png: Uint8Array | null = null;
  if (!body) {
    const zones = await db
      .select({ lat: privacyZones.lat, lon: privacyZones.lon, radiusM: privacyZones.radiusM })
      .from(privacyZones)
      .where(eq(privacyZones.userId, state.session.userId));
    png = await render(env.TRACKS, state, zones);
    if (!png) return null;
  } else if (conditional) {
    await body.cancel();
    body = null;
  }

  // Visibility, track state, or zones may have changed during the cache read or render.
  let current = false;
  try {
    current = (await currentSession(db, state)).length > 0;
    if (!current) return null;
  } finally {
    if (!current) await body?.cancel();
  }

  const headers = {
    "content-type": "image/png",
    "x-content-type-options": "nosniff",
    etag,
  };
  if (png) {
    waitUntil(
      caches.default
        .put(
          cacheKey,
          new Response(png, {
            headers: { ...headers, "cache-control": `public, max-age=${OG_EDGE_TTL_SECONDS}` },
          }),
        )
        .catch((error: unknown) => console.warn("Could not cache the route image.", error)),
    );
  }
  return new Response(conditional ? null : (png ?? body), {
    status: conditional ? 304 : 200,
    headers: { ...headers, "cache-control": "public, max-age=0, must-revalidate" },
  });
}
