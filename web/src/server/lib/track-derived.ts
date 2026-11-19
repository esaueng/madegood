import { insideZone, MERCATOR_MAX_LAT, SHARED_TRACK_MAX_FIXES, type Zone } from "./session-privacy";
import { TrackTooLarge } from "./track";

// Derived data the post-processing consumer stores for a session's track
// (docs/PLAN.md §7: "compute bbox/geohash"). Pure functions over a parsed track v1 file.

/** A bounding box in degrees. `west > east` when it crosses the antimeridian. */
export type Bounds = { south: number; west: number; north: number; east: number };

export type TrackDerived = {
  /** Every valid fix: the owner's view. */
  bounds: Bounds | null;
  /** Only the fixes others may see: what the shared track (session-privacy.ts) keeps. */
  publicBounds: Bounds | null;
  /** Geohash of the first fix in time, at START_GEOHASH_PRECISION. Owner-only. */
  startGeohash: string | null;
  /** First and last valid fix, epoch ms. */
  startedAt: number | null;
  endedAt: number | null;
};

/** 5 characters: a cell about 4.9 km × 4.9 km, enough to group sessions by spot. */
export const START_GEOHASH_PRECISION = 5;

const finite = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export class InvalidTrack extends Error {}

/**
 * The smallest longitude interval holding every value in `lons` (degrees, [-180, 180]),
 * found as the complement of the largest empty gap on the circle. Sorts `lons` in place.
 */
export function lonRange(lons: Float64Array): { west: number; east: number } | null {
  const n = lons.length;
  if (n === 0) return null;
  lons.sort();
  const first = lons[0] as number;
  const last = lons[n - 1] as number;
  // The gap that wraps through ±180, then each gap between neighbours.
  let gap = first + 360 - last;
  let west = first;
  let east = last;
  for (let i = 1; i < n; i++) {
    const inner = (lons[i] as number) - (lons[i - 1] as number);
    if (inner > gap) {
      gap = inner;
      west = lons[i] as number;
      east = lons[i - 1] as number;
    }
  }
  return { west, east };
}

/** The center of a box, handling boxes that cross the antimeridian. */
export function boundsCenter(bounds: Bounds): { lat: number; lon: number } {
  const span = (((bounds.east - bounds.west) % 360) + 360) % 360;
  let lon = bounds.west + span / 2;
  if (lon > 180) lon -= 360;
  return { lat: (bounds.south + bounds.north) / 2, lon };
}

const BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz";

export function geohash(lat: number, lon: number, precision: number): string {
  let [latMin, latMax, lonMin, lonMax] = [-90, 90, -180, 180];
  let hash = "";
  let bits = 0;
  let value = 0;
  let even = true;
  while (hash.length < precision) {
    if (even) {
      const mid = (lonMin + lonMax) / 2;
      value = value * 2 + (lon >= mid ? 1 : 0);
      if (lon >= mid) lonMin = mid;
      else lonMax = mid;
    } else {
      const mid = (latMin + latMax) / 2;
      value = value * 2 + (lat >= mid ? 1 : 0);
      if (lat >= mid) latMin = mid;
      else latMax = mid;
    }
    even = !even;
    if (++bits === 5) {
      hash += BASE32[value];
      bits = 0;
      value = 0;
    }
  }
  return hash;
}

/** Accumulates a box over fixes; longitudes go to a typed array for lonRange. */
class BoxBuilder {
  private south = Infinity;
  private north = -Infinity;
  private lons: Float64Array;
  private count = 0;
  constructor(capacity: number) {
    this.lons = new Float64Array(capacity);
  }
  add(lat: number, lon: number) {
    if (lat < this.south) this.south = lat;
    if (lat > this.north) this.north = lat;
    this.lons[this.count++] = lon;
  }
  build(): Bounds | null {
    const range = lonRange(this.lons.subarray(0, this.count));
    return range ? { south: this.south, north: this.north, ...range } : null;
  }
}

/**
 * Derives a track's bounds, start geohash and time range. Fixes count when their time and
 * position are finite and in range, as in shareTrack; `publicBounds` further leaves out
 * fixes inside `zones` and beyond Web Mercator's latitude limit, so it never covers a
 * position the shared track hides. Throws InvalidTrack for a document that is not a track
 * v1 file for `sessionId`, and TrackTooLarge above SHARED_TRACK_MAX_FIXES.
 */
export function deriveTrack(
  track: unknown,
  sessionId: string,
  zones: readonly Zone[],
): TrackDerived {
  if (!record(track) || track.v !== 1 || !record(track.gps)) {
    throw new InvalidTrack("not a track v1 document");
  }
  if (typeof track.sessionId !== "string" || track.sessionId.toLowerCase() !== sessionId) {
    throw new InvalidTrack("sessionId does not match the session");
  }
  const origin = typeof track.startedAt === "string" ? Date.parse(track.startedAt) : Number.NaN;
  if (!Number.isFinite(origin)) throw new InvalidTrack("startedAt is not a date");

  const gps = track.gps;
  const column = (key: string) => (Array.isArray(gps[key]) ? (gps[key] as unknown[]) : []);
  const [t, lat, lon] = [column("t"), column("lat"), column("lon")];
  // Bounded before allocating anything per fix, like shareTrack.
  if (t.length > SHARED_TRACK_MAX_FIXES) throw new TrackTooLarge();

  const all = new BoxBuilder(t.length);
  const visible = new BoxBuilder(t.length);
  let first = Infinity;
  let last = -Infinity;
  let start: { lat: number; lon: number } | null = null;
  for (let i = 0; i < t.length; i++) {
    const [ti, la, lo] = [t[i], lat[i], lon[i]];
    if (!finite(ti) || !finite(la) || !finite(lo) || Math.abs(la) > 90 || Math.abs(lo) > 180) {
      continue;
    }
    all.add(la, lo);
    if (ti < first) {
      first = ti;
      start = { lat: la, lon: lo };
    }
    if (ti > last) last = ti;
    if (Math.abs(la) <= MERCATOR_MAX_LAT && !insideZone({ lat: la, lon: lo }, zones)) {
      visible.add(la, lo);
    }
  }
  const time = (seconds: number) => {
    const ms = Math.round(origin + seconds * 1000);
    return Number.isFinite(ms) && Math.abs(ms) <= 8.64e15 ? ms : null;
  };
  return {
    bounds: all.build(),
    publicBounds: visible.build(),
    startGeohash: start ? geohash(start.lat, start.lon, START_GEOHASH_PRECISION) : null,
    startedAt: start ? time(first) : null,
    endedAt: start ? time(last) : null,
  };
}
