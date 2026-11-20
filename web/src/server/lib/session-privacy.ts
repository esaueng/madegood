import { TrackTooLarge } from "./track";
import { distanceM, ZONE_MARGIN_M } from "./voyage-sharing";

// What others see of a session's track (docs/PLAN.md §7: "privacy zones cut out on the
// server"). The owner always gets the stored file; everyone else gets this projection.

export type Zone = { lat: number; lon: number; radiusM: number };

/** Event types others may see, with only these numeric data fields. Marks and MOB stay private. */
const SHARED_EVENTS: Record<string, readonly string[]> = {
  start: [],
  stop: [],
  pause: [],
  resume: [],
  lap: [],
  tack: ["durationS"],
  gybe: ["durationS"],
};

/**
 * Added to shared tracks before the first fix after hidden fixes, or between two fixes
 * whose connecting line might pass through a zone. `data.index` is that fix's index in the
 * shared GPS columns; readers must not draw a line from the fix before it.
 */
export const PRIVACY_GAP_EVENT = "privacyGap";

const finite = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Web Mercator's latitude limit (atan(sinh(π))), where maps clamp positions. Shared
 * copies leave out fixes beyond it.
 */
export const MERCATOR_MAX_LAT = 85.0511287798066;

/** Most GPS fixes a shared copy is built from: about 139 hours at 1 Hz. */
export const SHARED_TRACK_MAX_FIXES = 500_000;

export const insideZone = (fix: { lat: number; lon: number }, zones: readonly Zone[]) =>
  zones.some((zone) => distanceM(zone, fix) <= zone.radiusM + ZONE_MARGIN_M);

const EARTH_RADIUS_M = 6_371_008.8;
const radians = (degrees: number) => (degrees * Math.PI) / 180;

/** Longitude change from `a` to `b` the short way round, degrees in [-180, 180). */
export const lonDelta = (a: number, b: number) => ((((b - a) % 360) + 540) % 360) - 180;

/**
 * An upper bound on the length of any line a viewer may draw between `a` and `b`: the
 * great-circle arc, or any path that moves monotonically in latitude and in longitude the
 * short way round (a straight line on a Mercator map, or linear interpolation in degrees,
 * as the website does). Such a path is at most R·(|Δφ| + cos φ*·|Δλ|), where φ* is the
 * latitude in the box nearest the equator.
 */
export function drawnLengthBoundM(
  a: { lat: number; lon: number },
  b: { lat: number; lon: number },
) {
  const dLat = Math.abs(radians(b.lat - a.lat));
  const dLon = Math.abs(radians(lonDelta(a.lon, b.lon)));
  const nearestEquator =
    Math.sign(a.lat) !== Math.sign(b.lat) ? 0 : Math.min(Math.abs(a.lat), Math.abs(b.lat));
  const boxPath = EARTH_RADIUS_M * (dLat + Math.cos(radians(nearestEquator)) * dLon);
  return Math.max(distanceM(a, b), boxPath);
}

/**
 * Whether every line a viewer may draw from `a` to `b` provably stays outside every zone.
 * A path of length P through a point within r of a zone center has d(z,a) + d(z,b) at most
 * P + 2r (triangle inequality), so the pair is joined only when the sum is larger, with P
 * from drawnLengthBoundM. Near misses count as possible crossings.
 */
export const arcClearsZones = (
  a: { lat: number; lon: number },
  b: { lat: number; lon: number },
  zones: readonly Zone[],
) => {
  const length = drawnLengthBoundM(a, b);
  return zones.every(
    (zone) => distanceM(zone, a) + distanceM(zone, b) > length + 2 * (zone.radiusM + ZONE_MARGIN_M),
  );
};

/**
 * The track v1 document others may see: fixes inside a zone removed, a `privacyGap` event
 * wherever the line must break, no heart rate, allowlisted events without free-form data,
 * no optional GPS columns, and the shared summary. Returns null when `track` is not a
 * track v1 document; throws TrackTooLarge above the fix limit.
 */
export function shareTrack(
  track: unknown,
  zones: readonly Zone[],
  summary: Record<string, unknown> | null,
  maxFixes = SHARED_TRACK_MAX_FIXES,
): Record<string, unknown> | null {
  if (!record(track) || track.v !== 1 || !record(track.gps)) return null;
  const gps = track.gps;
  const t = Array.isArray(gps.t) ? gps.t : [];
  const column = (key: string) => (Array.isArray(gps[key]) ? (gps[key] as unknown[]) : []);
  const [lat, lon, spd, crs, hacc] = ["lat", "lon", "spd", "crs", "hacc"].map(column) as [
    unknown[],
    unknown[],
    unknown[],
    unknown[],
    unknown[],
  ];

  // Bounded before allocating anything per fix (re-check of #64).
  if (t.length > maxFixes) throw new TrackTooLarge();

  // Fixes without a usable time or position are dropped. That is safe: whether a line may
  // join the visible fixes on either side is decided from those two fixes alone. So are
  // fixes beyond Web Mercator's latitude limit: a map clamps them to its edge, where the
  // line it draws is not the one the crossing check bounds; a gap marks where they were.
  // Columns are read in place; the only per-fix allocation is one index array.
  const valid = new Uint32Array(t.length);
  let count = 0;
  const beyondMap = new Set<number>();
  for (let i = 0; i < t.length; i++) {
    const [ti, la, lo] = [t[i], lat[i], lon[i]];
    if (!finite(ti) || !finite(la) || !finite(lo) || Math.abs(la) > 90 || Math.abs(lo) > 180) {
      continue;
    }
    if (Math.abs(la) > MERCATOR_MAX_LAT) beyondMap.add(i);
    valid[count++] = i;
  }
  // Stable sort by time, so lines and gaps follow time order (docs/formats.md).
  const order = Array.from(valid.subarray(0, count)).sort(
    (a, b) => (t[a] as number) - (t[b] as number) || a - b,
  );

  const out = {
    t: [] as number[],
    lat: [] as number[],
    lon: [] as number[],
    spd: [] as unknown[],
    crs: [] as unknown[],
    hacc: [] as unknown[],
  };
  // Gaps are marked by the index of the first fix after them in the shared columns, never
  // by time alone: fixes on both sides of a zone can share a timestamp.
  const gaps: { t: number; index: number }[] = [];
  let previous = -1;
  let hiddenSincePrevious = false;
  for (const i of order) {
    const fix = { lat: lat[i] as number, lon: lon[i] as number };
    if (beyondMap.has(i) || insideZone(fix, zones)) {
      hiddenSincePrevious = true;
      continue;
    }
    const before =
      previous < 0 ? null : { lat: lat[previous] as number, lon: lon[previous] as number };
    if (before && (hiddenSincePrevious || !arcClearsZones(before, fix, zones))) {
      gaps.push({ t: t[i] as number, index: out.t.length });
    }
    out.t.push(t[i] as number);
    out.lat.push(fix.lat);
    out.lon.push(fix.lon);
    out.spd.push(finite(spd[i]) ? spd[i] : null);
    out.crs.push(finite(crs[i]) ? crs[i] : null);
    out.hacc.push(finite(hacc[i]) ? hacc[i] : null);
    previous = i;
    hiddenSincePrevious = false;
  }

  const events: Record<string, unknown>[] = [];
  for (const event of Array.isArray(track.events) ? track.events : []) {
    if (!record(event) || !finite(event.t) || typeof event.type !== "string") continue;
    const fields = SHARED_EVENTS[event.type];
    if (!Object.hasOwn(SHARED_EVENTS, event.type) || !fields) continue;
    const data: Record<string, number> = {};
    for (const key of fields) {
      const value = record(event.data) ? event.data[key] : undefined;
      if (finite(value)) data[key] = value;
    }
    events.push(
      Object.keys(data).length > 0
        ? { t: event.t, type: event.type, data }
        : { t: event.t, type: event.type },
    );
  }
  for (const gap of gaps) {
    events.push({ t: gap.t, type: PRIVACY_GAP_EVENT, data: { index: gap.index } });
  }
  events.sort((a, b) => (a.t as number) - (b.t as number));

  const shared: Record<string, unknown> = {
    v: 1,
    sessionId: track.sessionId,
    sport: track.sport,
    startedAt: track.startedAt,
    gps: out,
    hr: { t: [], bpm: [] },
    events,
  };
  if (summary !== null) shared.summary = summary;
  if (typeof track.analyzerVersion === "string") shared.analyzerVersion = track.analyzerVersion;
  return shared;
}
