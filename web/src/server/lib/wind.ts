import { z } from "@hono/zod-openapi";
import { readBody } from "./track";

// Server-side wind for a session from Open-Meteo (docs/PLAN.md §7 queue consumer; what is
// sent is documented in docs/self-hosting.md "Post-processing"). Only for sessions others
// can see: private sessions never cause a request. A request carries only:
// - one position, the center of the session's *public* bounds (privacy zones already cut
//   out), rounded to WIND_GRID_DEG;
// - the UTC calendar dates the session spans;
// - the fixed list of variables and units below.
// No account, session ID, track, or time of day is sent.

/** Rounding for the position sent: 0.1° is about 11 km, near the models' own grid. */
export const WIND_GRID_DEG = 0.1;
/** Sessions that ended longer ago than this use the reanalysis archive. */
const FORECAST_MAX_AGE_MS = 60 * 24 * 3600 * 1000;
const FORECAST_URL = "https://api.open-meteo.com/v1/forecast";
const ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive";
const TIMEOUT_MS = 10_000;
/** 8 days of hourly values is a few KiB; anything far larger is not the expected answer. */
const RESPONSE_MAX_BYTES = 256 * 1024;
const MAX_SAMPLES = 8 * 24 + 1;

/** Stored in sessions.wind_json. */
export type StoredWind =
  | {
      status: "ok";
      source: "open-meteo-forecast" | "open-meteo-archive";
      /** Mean direction the wind blows from, degrees true (vector mean of the samples). */
      directionDeg: number | null;
      /** Mean speed at 10 m, m/s. */
      speedMps: number | null;
      /** Strongest hourly gust at 10 m, m/s. */
      gustMps: number | null;
      samples: {
        t: number;
        directionDeg: number | null;
        speedMps: number | null;
        gustMps: number | null;
      }[];
      fetchedAt: number;
    }
  | { status: "unavailable"; reason: string; fetchedAt: number };

/** Network failures, timeouts, 429 and 5xx: worth retrying later. */
export class WindTransientError extends Error {}

const nullableNumbers = z.array(z.number().finite().nullable());
const OpenMeteoHourly = z.object({
  hourly: z.object({
    time: z.array(z.number().int()),
    wind_speed_10m: nullableNumbers,
    wind_direction_10m: nullableNumbers,
    wind_gusts_10m: nullableNumbers.optional(),
  }),
});

const roundTo = (value: number, step: number) =>
  Number((Math.round(value / step) * step).toFixed(4));
const utcDate = (ms: number) => new Date(ms).toISOString().slice(0, 10);

/** The request for a session's window, or null when the window is unusable. */
export function windRequest(
  center: { lat: number; lon: number },
  window: { startedAt: number; endedAt: number },
  now = Date.now(),
): URL | null {
  const { startedAt, endedAt } = window;
  if (!(endedAt >= startedAt) || endedAt - startedAt > 8 * 24 * 3600 * 1000) return null;
  if (startedAt > now) return null;
  const archive = now - endedAt > FORECAST_MAX_AGE_MS;
  const url = new URL(archive ? ARCHIVE_URL : FORECAST_URL);
  let lon = roundTo(center.lon, WIND_GRID_DEG);
  if (lon > 180) lon -= 360;
  const params = {
    latitude: String(roundTo(Math.max(-90, Math.min(90, center.lat)), WIND_GRID_DEG)),
    longitude: String(lon),
    start_date: utcDate(startedAt),
    end_date: utcDate(endedAt),
    hourly: "wind_speed_10m,wind_direction_10m,wind_gusts_10m",
    wind_speed_unit: "ms",
    timeformat: "unixtime",
    timezone: "GMT",
  };
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return url;
}

/**
 * Fetches hourly wind for the session window and summarizes the hours it overlaps (the
 * hour before the start through the hour after the end). Throws WindTransientError when a
 * retry may help; returns `unavailable` when it will not.
 */
export async function fetchWind(
  url: URL,
  window: { startedAt: number; endedAt: number },
  fetcher: typeof fetch = fetch,
  now = Date.now(),
): Promise<StoredWind> {
  const unavailable = (reason: string): StoredWind => ({
    status: "unavailable",
    reason,
    fetchedAt: now,
  });
  let response: Response;
  try {
    response = await fetcher(url, {
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (error) {
    throw new WindTransientError(`Open-Meteo request failed: ${String(error)}`);
  }
  if (response.status === 429 || response.status >= 500) {
    await response.body?.cancel();
    throw new WindTransientError(`Open-Meteo answered ${response.status}`);
  }
  if (!response.ok) {
    await response.body?.cancel();
    return unavailable(`http_${response.status}`);
  }
  const bytes = await readBody(response.body, RESPONSE_MAX_BYTES);
  if (!bytes) return unavailable("response_too_large");
  let parsed: z.infer<typeof OpenMeteoHourly>;
  try {
    parsed = OpenMeteoHourly.parse(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    return unavailable("unexpected_response");
  }

  const hour = 3600 * 1000;
  const from = Math.floor(window.startedAt / hour) * hour - hour;
  const to = Math.ceil(window.endedAt / hour) * hour + hour;
  const { time, wind_speed_10m: speed, wind_direction_10m: direction } = parsed.hourly;
  const gusts = parsed.hourly.wind_gusts_10m ?? [];
  const samples: Extract<StoredWind, { status: "ok" }>["samples"] = [];
  for (let i = 0; i < time.length && samples.length < MAX_SAMPLES; i++) {
    const t = (time[i] as number) * 1000;
    if (t < from || t > to) continue;
    samples.push({
      t,
      speedMps: speed[i] ?? null,
      directionDeg: direction[i] ?? null,
      gustMps: gusts[i] ?? null,
    });
  }
  if (samples.length === 0) return unavailable("no_data");

  // Vector mean of the "from" directions, weighted by speed; mean of the speeds.
  let [u, v, sum, count, gust] = [0, 0, 0, 0, null as number | null];
  for (const sample of samples) {
    if (sample.speedMps !== null) {
      sum += sample.speedMps;
      count += 1;
      if (sample.directionDeg !== null) {
        const rad = (sample.directionDeg * Math.PI) / 180;
        u += sample.speedMps * Math.sin(rad);
        v += sample.speedMps * Math.cos(rad);
      }
    }
    if (sample.gustMps !== null) gust = Math.max(gust ?? 0, sample.gustMps);
  }
  const directionDeg =
    u === 0 && v === 0
      ? null
      : Number((((((Math.atan2(u, v) * 180) / Math.PI) % 360) + 360) % 360).toFixed(1));
  return {
    status: "ok",
    source:
      url.origin === new URL(ARCHIVE_URL).origin ? "open-meteo-archive" : "open-meteo-forecast",
    directionDeg,
    speedMps: count > 0 ? Number((sum / count).toFixed(2)) : null,
    gustMps: gust,
    samples,
    fetchedAt: now,
  };
}
