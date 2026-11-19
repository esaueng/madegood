// Track v1 (docs/formats.md) for the session page: decoding, segments, replay lookups and
// the speed-colored map geometry. Pure functions, so tests run them without a browser.

export type Fix = { t: number; lat: number; lon: number; spd: number | null };
export type HeartRate = { t: number; bpm: number };
export type TrackEvent = { t: number; type: string; data?: Record<string, unknown> | null };

export type Track = {
  startedAt: string;
  /** Valid fixes sorted by time. */
  fixes: Fix[];
  /** Index ranges [from, to) into `fixes`; lines are never drawn between segments. */
  segments: [number, number][];
  hr: HeartRate[];
  events: TrackEvent[];
  /** Seconds from start to the last sample. */
  endT: number;
};

/** Consecutive fixes further apart than this are not joined (GPXWriter.defaultSegmentGap). */
export const SEGMENT_GAP_S = 30;

const finite = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);

const column = (source: Record<string, unknown> | undefined, key: string): unknown[] =>
  Array.isArray(source?.[key]) ? (source[key] as unknown[]) : [];

// Manual and auto pauses are both `pause`/`resume` events (docs/metrics.md).
const isPause = (type: string) => type === "pause";
const isResume = (type: string) => type === "resume";

export function parseTrack(json: unknown): Track {
  const doc = (json ?? {}) as Record<string, unknown>;
  if (doc.v !== 1) throw new Error("Unsupported track version");
  const gps = doc.gps as Record<string, unknown> | undefined;
  const t = column(gps, "t");
  const lat = column(gps, "lat");
  const lon = column(gps, "lon");
  const spd = column(gps, "spd");
  const fixes: Fix[] = [];
  for (let i = 0; i < t.length; i++) {
    const [ti, la, lo, sp] = [t[i], lat[i], lon[i], spd[i]];
    if (!finite(ti) || !finite(la) || !finite(lo) || Math.abs(la) > 90 || Math.abs(lo) > 180) {
      continue;
    }
    fixes.push({ t: ti, lat: la, lon: lo, spd: finite(sp) && sp >= 0 ? sp : null });
  }
  // Stable sort: equal times keep their stored order (docs/formats.md).
  fixes.sort((a, b) => a.t - b.t);

  const hrSource = doc.hr as Record<string, unknown> | undefined;
  const hrT = column(hrSource, "t");
  const bpm = column(hrSource, "bpm");
  const hr: HeartRate[] = [];
  for (let i = 0; i < hrT.length; i++) {
    const [ti, b] = [hrT[i], bpm[i]];
    if (finite(ti) && finite(b) && b > 0) hr.push({ t: ti, bpm: b });
  }
  hr.sort((a, b) => a.t - b.t);

  const events: TrackEvent[] = (Array.isArray(doc.events) ? doc.events : [])
    .filter(
      (e): e is TrackEvent =>
        typeof e === "object" && e !== null && finite(e.t) && typeof e.type === "string",
    )
    .sort((a, b) => a.t - b.t);

  const endT = Math.max(fixes.at(-1)?.t ?? 0, hr.at(-1)?.t ?? 0, 0);
  return {
    startedAt: typeof doc.startedAt === "string" ? doc.startedAt : "",
    fixes,
    segments: segmentsOf(fixes, events),
    hr,
    events,
    endT,
  };
}

/** Splits at time gaps over SEGMENT_GAP_S and at the first fix after a resume that follows a pause. */
export function segmentsOf(fixes: Fix[], events: TrackEvent[]): [number, number][] {
  const breaks: number[] = [];
  let paused = false;
  for (const event of events) {
    if (isPause(event.type)) paused = true;
    else if (isResume(event.type) && paused) {
      paused = false;
      breaks.push(event.t);
    }
  }
  const segments: [number, number][] = [];
  let from = 0;
  let nextBreak = 0;
  const t = (i: number) => (fixes[i] as Fix).t;
  for (let i = 1; i <= fixes.length; i++) {
    let split = i === fixes.length || t(i) - t(i - 1) > SEGMENT_GAP_S;
    while (i < fixes.length && nextBreak < breaks.length && (breaks[nextBreak] as number) <= t(i)) {
      if ((breaks[nextBreak] as number) > t(i - 1)) split = true;
      nextBreak++;
    }
    if (split) {
      if (i > from) segments.push([from, i]);
      from = i;
    }
  }
  return segments;
}

/** Index of the last fix at or before `t`, or -1. Binary search over sorted times. */
export function fixIndexAt(fixes: Fix[], t: number): number {
  let lo = 0;
  let hi = fixes.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if ((fixes[mid] as Fix).t <= t) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return found;
}

/** The interpolated position and speed at `t`, within a segment; null in a gap. */
export function positionAt(track: Track, t: number): Fix | null {
  const i = fixIndexAt(track.fixes, t);
  if (i < 0) return null;
  const segment = track.segments.find(([from, to]) => i >= from && i < to);
  if (!segment) return null;
  const a = track.fixes[i] as Fix;
  const b = i + 1 < segment[1] ? (track.fixes[i + 1] as Fix) : null;
  if (!b || b.t === a.t) return t - a.t <= SEGMENT_GAP_S ? a : null;
  const k = Math.min(1, Math.max(0, (t - a.t) / (b.t - a.t)));
  const spd = a.spd !== null && b.spd !== null ? a.spd + (b.spd - a.spd) * k : (a.spd ?? b.spd);
  return { t, lat: a.lat + (b.lat - a.lat) * k, lon: a.lon + (b.lon - a.lon) * k, spd };
}

/** The latest heart rate reading at or before `t` (within a minute), or null. */
export function heartRateAt(hr: HeartRate[], t: number): number | null {
  let lo = 0;
  let hi = hr.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if ((hr[mid] as HeartRate).t <= t) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  const reading = hr[found];
  return reading && t - reading.t <= 60 ? reading.bpm : null;
}

/** The speed the color scale tops out at: the 98th percentile, so one spike does not wash it out. */
export function speedScaleMax(fixes: Fix[]): number {
  const speeds = fixes.flatMap((f) => (f.spd === null ? [] : [f.spd])).sort((a, b) => a - b);
  if (speeds.length === 0) return 1;
  const p98 = speeds[Math.min(speeds.length - 1, Math.floor(speeds.length * 0.98))] ?? 1;
  return Math.max(0.5, p98);
}

export const SPEED_BINS = 8;

type LineFeature = {
  type: "Feature";
  properties: { bin: number };
  geometry: { type: "LineString"; coordinates: [number, number][] };
};

/**
 * The track as LineStrings, each a run of consecutive fixes whose pair speeds fall in the
 * same color bin (0 … SPEED_BINS - 1, or -1 for unknown speed). Merging runs keeps the
 * feature count small for long sessions.
 */
export function speedLines(track: Track, maxSpeed: number) {
  const features: LineFeature[] = [];
  const binOf = (a: Fix, b: Fix) => {
    const speeds = [a.spd, b.spd].filter((s): s is number => s !== null);
    if (speeds.length === 0) return -1;
    const mean = speeds.reduce((sum, s) => sum + s, 0) / speeds.length;
    return Math.min(SPEED_BINS - 1, Math.floor((mean / maxSpeed) * SPEED_BINS));
  };
  for (const [from, to] of track.segments) {
    let current: LineFeature | null = null;
    for (let i = from + 1; i < to; i++) {
      const a = track.fixes[i - 1] as Fix;
      const b = track.fixes[i] as Fix;
      const bin = binOf(a, b);
      if (!current || current.properties.bin !== bin) {
        current = {
          type: "Feature",
          properties: { bin },
          geometry: { type: "LineString", coordinates: [[a.lon, a.lat]] },
        };
        features.push(current);
      }
      current.geometry.coordinates.push([b.lon, b.lat]);
    }
  }
  return { type: "FeatureCollection" as const, features };
}

/** [[minLon, minLat], [maxLon, maxLat]] over all fixes, or null without any. */
export function bounds(fixes: Fix[]): [[number, number], [number, number]] | null {
  if (fixes.length === 0) return null;
  let [minLon, minLat, maxLon, maxLat] = [180, 90, -180, -90];
  for (const f of fixes) {
    minLon = Math.min(minLon, f.lon);
    maxLon = Math.max(maxLon, f.lon);
    minLat = Math.min(minLat, f.lat);
    maxLat = Math.max(maxLat, f.lat);
  }
  return [
    [minLon, minLat],
    [maxLon, maxLat],
  ];
}

/** Evenly thins a series to at most `max` points for charts, keeping the last one. */
export function thin<T>(items: T[], max: number): T[] {
  if (items.length <= max) return items;
  const step = items.length / max;
  const out: T[] = [];
  for (let i = 0; i < max; i++) out.push(items[Math.floor(i * step)] as T);
  const last = items.at(-1);
  if (last !== undefined && out.at(-1) !== last) out.push(last);
  return out;
}

export const MANEUVER_TYPES = new Set(["tack", "gybe"]);

/** Downloads and inflates a session's track. Null when it has none or it is withheld. */
export async function fetchTrack(
  fetcher: (path: string) => Promise<Response>,
  id: string,
): Promise<Track | null> {
  const response = await fetcher(`/sessions/${encodeURIComponent(id)}/track`);
  if (response.status === 404 || response.status === 403) return null;
  if (!response.ok || !response.body) throw new Error(`Track download failed: ${response.status}`);
  const text = await new Response(
    response.body.pipeThrough(new DecompressionStream("gzip")),
  ).text();
  return parseTrack(JSON.parse(text));
}

/** What the page shows: heart rate is the owner's alone (the API also withholds it). */
export const trackForViewer = (track: Track, isOwner: boolean): Track =>
  isOwner ? track : { ...track, hr: [] };
