import { z } from "@hono/zod-openapi";
import { importPKCS8, SignJWT } from "jose";
import { readBody } from "./track";

const WEATHERKIT_URL = "https://weatherkit.apple.com/api/v1/weather/en";
const TOKEN_LIFETIME_SECONDS = 60 * 60;
const TOKEN_REFRESH_SECONDS = 30;
const TIMEOUT_MS = 10_000;
const HOUR_MS = 3_600_000;
const MAX_SESSION_HOURS = 8 * 24;
const MAX_SAMPLES = MAX_SESSION_HOURS + 5;
const FIRST_HISTORICAL_HOUR = Date.UTC(2021, 7, 1);
const MAX_FORECAST_HOURS = 240;
const RESPONSE_MAX_BYTES = 256 * 1024;

const WindValues = z.object({
  directionDeg: z.number().finite().nullable(),
  speedMps: z.number().finite().nullable(),
  gustMps: z.number().finite().nullable(),
});
const WindSample = WindValues.extend({ t: z.number().int() });
const WindResult = WindValues.extend({
  status: z.literal("ok"),
  samples: z.array(WindSample),
  fetchedAt: z.number().int(),
});
// Keep the original source values readable for unversioned rows and existing API clients.
const LEGACY_WIND_SOURCES = ["open-meteo-forecast", "open-meteo-archive"] as const;
const WEATHERKIT_SOURCE = "weatherkit";
export const WindSource = z.enum([...LEGACY_WIND_SOURCES, WEATHERKIT_SOURCE]);
const WeatherKitWind = WindResult.extend({ v: z.literal(1), source: z.literal(WEATHERKIT_SOURCE) });
const ReadableWind = z.union([
  WindResult.extend({ v: z.undefined().optional(), source: z.enum(LEGACY_WIND_SOURCES) }),
  WeatherKitWind,
]);

/** Stored in sessions.wind_json. Direction is wind FROM in degrees true. Speeds are m/s. */
export type StoredWind =
  | z.infer<typeof WeatherKitWind>
  | { v: 1; status: "unavailable"; reason: string; fetchedAt: number };

export function readStoredWind(json: string | null): z.infer<typeof ReadableWind> | null {
  if (json === null) return null;
  try {
    return ReadableWind.safeParse(JSON.parse(json)).data ?? null;
  } catch {
    return null;
  }
}

/** Network failures, timeouts, 429 and 5xx: worth retrying later. */
export class WindTransientError extends Error {}

export type WeatherKitCredentials = {
  privateKey: string;
  keyId: string;
  teamId: string;
  serviceId: string;
};

export function weatherKitCredentials(env: WeatherKitSecrets): WeatherKitCredentials | null {
  const privateKey = env.WEATHERKIT_PRIVATE_KEY?.trim();
  const keyId = env.WEATHERKIT_KEY_ID?.trim();
  const teamId = env.WEATHERKIT_TEAM_ID?.trim();
  const serviceId = env.WEATHERKIT_SERVICE_ID?.trim();
  return privateKey && keyId && teamId && serviceId
    ? { privateKey, keyId, teamId, serviceId }
    : null;
}

let cachedToken:
  | (WeatherKitCredentials & { issuedAt: number; expiresAt: number; jwt: string })
  | undefined;

export async function weatherKitToken(
  credentials: WeatherKitCredentials,
  now: number,
): Promise<string | null> {
  const { privateKey, keyId, teamId, serviceId } = credentials;
  const issuedAt = Math.floor(now / 1000);
  if (
    cachedToken &&
    cachedToken.privateKey === privateKey &&
    cachedToken.keyId === keyId &&
    cachedToken.teamId === teamId &&
    cachedToken.serviceId === serviceId &&
    issuedAt >= cachedToken.issuedAt &&
    issuedAt < cachedToken.expiresAt - TOKEN_REFRESH_SECONDS
  ) {
    return cachedToken.jwt;
  }

  try {
    // jose imports the .p8 PKCS#8 key and signs with the Worker's WebCrypto implementation.
    const key = await importPKCS8(privateKey.replaceAll("\\n", "\n"), "ES256");
    const expiresAt = issuedAt + TOKEN_LIFETIME_SECONDS;
    const jwt = await new SignJWT({ iss: teamId, sub: serviceId, iat: issuedAt, exp: expiresAt })
      .setProtectedHeader({ alg: "ES256", kid: keyId, id: `${teamId}.${serviceId}` })
      .sign(key);
    cachedToken = { ...credentials, issuedAt, expiresAt, jwt };
    return jwt;
  } catch {
    return null;
  }
}

const WeatherKitHourly = z.object({
  forecastHourly: z
    .object({
      hours: z.array(
        z.object({
          forecastStart: z.iso.datetime({ offset: true }),
          windSpeed: z.number().finite().nonnegative(),
          windDirection: z.number().finite().nullish(),
          windGust: z.number().finite().nonnegative().nullish(),
        }),
      ),
    })
    .optional(),
});

export const unavailableWind = (reason: string, now: number): StoredWind => ({
  v: 1,
  status: "unavailable",
  reason,
  fetchedAt: now,
});

const floorHour = (ms: number) => Math.floor(ms / HOUR_MS) * HOUR_MS;
// Mirror WaterKit's WeatherGridCell, including ties away from zero, the poles and ±180°.
const gridIndex = (degrees: number) => Math.sign(degrees) * Math.round(Math.abs(degrees) * 10);

/** Only the rounded public-bounds center and whole UTC hours leave the Worker. */
export function windRequest(
  center: { lat: number; lon: number },
  window: { startedAt: number; endedAt: number },
  now = Date.now(),
): URL | null {
  const { startedAt, endedAt } = window;
  if (!(endedAt >= startedAt) || endedAt - startedAt > MAX_SESSION_HOURS * HOUR_MS) return null;
  if (startedAt > now || endedAt < FIRST_HISTORICAL_HOUR) return null;

  const lat = gridIndex(center.lat);
  const meridian = gridIndex(center.lon);
  const lon = Math.abs(lat) === 900 ? 0 : meridian === 1800 ? -1800 : meridian;
  const url = new URL(`${WEATHERKIT_URL}/${lat / 10}/${lon / 10}`);
  // Include the hour before the start through the hour after the end. The end is exclusive.
  const from = Math.max(FIRST_HISTORICAL_HOUR, floorHour(startedAt) - HOUR_MS);
  const to = Math.min(
    floorHour(now) + MAX_FORECAST_HOURS * HOUR_MS,
    (Math.ceil(endedAt / HOUR_MS) + 2) * HOUR_MS,
  );
  url.search = new URLSearchParams({
    dataSets: "forecastHourly",
    hourlyStart: new Date(from).toISOString(),
    hourlyEnd: new Date(to).toISOString(),
    timezone: "UTC",
  }).toString();
  return url;
}

/** Throws WindTransientError when a retry may help; otherwise returns modelled wind or unavailable. */
export async function fetchWind(
  token: string,
  url: URL,
  fetcher: typeof fetch = fetch,
  now = Date.now(),
): Promise<StoredWind> {
  let bytes: Uint8Array | null;
  try {
    const response = await fetcher(url, {
      headers: { accept: "application/json", authorization: `Bearer ${token}` },
      redirect: "manual",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 429 || response.status >= 500) {
        throw new WindTransientError(`WeatherKit answered ${response.status}`);
      }
      return unavailableWind(`http_${response.status}`, now);
    }
    bytes = await readBody(response.body, RESPONSE_MAX_BYTES);
  } catch (error) {
    if (error instanceof WindTransientError) throw error;
    throw new WindTransientError("WeatherKit request failed");
  }
  if (!bytes) return unavailableWind("response_too_large", now);

  let parsed: z.infer<typeof WeatherKitHourly>;
  try {
    parsed = WeatherKitHourly.parse(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    return unavailableWind("unexpected_response", now);
  }

  const from = Date.parse(url.searchParams.get("hourlyStart") ?? "");
  const to = Date.parse(url.searchParams.get("hourlyEnd") ?? "");
  const samples: z.infer<typeof WindSample>[] = [];
  for (const hour of parsed.forecastHourly?.hours ?? []) {
    const t = Date.parse(hour.forecastStart);
    if (t < from || t >= to) continue;
    samples.push({
      t,
      speedMps: hour.windSpeed / 3.6,
      directionDeg: hour.windDirection ?? null,
      gustMps: hour.windGust == null ? null : hour.windGust / 3.6,
    });
    if (samples.length === MAX_SAMPLES) break;
  }
  if (samples.length === 0) return unavailableWind("no_data", now);

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
      : Number((((((Math.atan2(u, v) * 180) / Math.PI) % 360) + 360) % 360).toFixed(1)) % 360;
  return {
    v: 1,
    status: "ok",
    source: "weatherkit",
    directionDeg,
    speedMps: count > 0 ? Number((sum / count).toFixed(2)) : null,
    gustMps: gust,
    samples,
    fetchedAt: now,
  };
}
