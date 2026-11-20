import { decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { describe, expect, it, vi } from "vitest";
import {
  fetchWind,
  WindTransientError,
  weatherKitToken,
  windRequest,
} from "../src/server/lib/wind";

const now = Date.parse("2022-02-01T00:00:00Z");
const hour = 3_600_000;
const window = {
  startedAt: Date.parse("2022-01-01T10:03:04Z"),
  endedAt: Date.parse("2022-01-01T11:23:45Z"),
};
const url = windRequest({ lat: 0.12345, lon: -0.06789 }, window, now) as URL;
const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
const credentials = {
  privateKey: await exportPKCS8(privateKey),
  keyId: "test-key",
  teamId: "test-team",
  serviceId: "test.weatherkit",
};

describe("WeatherKit hourly wind", () => {
  it("sends only the coarse cell, whole UTC hours and fixed dataset to Apple", () => {
    expect(url.origin).toBe("https://weatherkit.apple.com");
    expect(url.pathname).toBe("/api/v1/weather/en/0.1/-0.1");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      dataSets: "forecastHourly",
      hourlyStart: "2022-01-01T09:00:00.000Z",
      hourlyEnd: "2022-01-01T14:00:00.000Z",
      timezone: "UTC",
    });
    expect(url.href).not.toContain("0.12345");
    expect(url.href).not.toContain("-0.06789");
  });

  it("rounds ties and canonicalizes poles and antimeridian like WaterKit", () => {
    expect(windRequest({ lat: -0.05, lon: 179.99 }, window, now)?.pathname).toBe(
      "/api/v1/weather/en/-0.1/-180",
    );
    expect(windRequest({ lat: 89.999, lon: 37.12 }, window, now)?.pathname).toBe(
      "/api/v1/weather/en/90/0",
    );
  });

  it("skips unusable windows and caps the historical request at WeatherKit's first hour", () => {
    const center = { lat: 0, lon: 0 };
    const first = Date.parse("2021-08-01T00:00:00Z");
    expect(windRequest(center, { startedAt: first - hour, endedAt: first - 1 }, now)).toBeNull();
    expect(windRequest(center, { startedAt: now + 1, endedAt: now + 1 }, now)).toBeNull();
    expect(windRequest(center, { startedAt: now, endedAt: now - 1 }, now)).toBeNull();
    expect(windRequest(center, { startedAt: now - 193 * hour, endedAt: now }, now)).toBeNull();
    expect(
      windRequest(center, { startedAt: first - hour, endedAt: first }, now)?.searchParams.get(
        "hourlyStart",
      ),
    ).toBe("2021-08-01T00:00:00.000Z");
  });

  it("signs the exact Apple claims with ES256, caches the JWT, and refreshes it", async () => {
    const escaped = { ...credentials, privateKey: credentials.privateKey.replaceAll("\n", "\\n") };
    const token = await weatherKitToken(escaped, now);
    expect(token).toBeTruthy();
    expect(await weatherKitToken(escaped, now + hour - 60_000)).toBe(token);
    expect(await weatherKitToken(escaped, now + hour)).not.toBe(token);
    const rotated = await weatherKitToken({ ...escaped, keyId: "rotated-key" }, now + hour);
    const issued = now / 1000;
    expect(decodeProtectedHeader(token ?? "")).toEqual({
      alg: "ES256",
      kid: credentials.keyId,
      id: `${credentials.teamId}.${credentials.serviceId}`,
    });
    const { payload } = await jwtVerify(token ?? "", publicKey, {
      algorithms: ["ES256"],
      currentDate: new Date(now),
    });
    expect(payload).toEqual({
      iss: credentials.teamId,
      sub: credentials.serviceId,
      iat: issued,
      exp: issued + 3600,
    });
    expect(decodeProtectedHeader(rotated ?? "").kid).toBe("rotated-key");
  });

  it("maps hourly km/h to m/s and summarizes wind FROM across north", async () => {
    const response = (
      forecastStart: string,
      windSpeed: number,
      windDirection?: number,
      windGust?: number,
    ) => ({
      forecastStart: `2022-01-01T${forecastStart}:00Z`,
      windSpeed,
      windDirection,
      windGust,
    });
    const fetcher: typeof fetch = async (request, init) => {
      expect(String(request)).toBe(url.href);
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer test-token");
      expect(init?.redirect).toBe("manual");
      return Response.json({
        forecastHourly: {
          hours: [
            response("08:00", 360, 90),
            response("09:00", 18, 350),
            response("10:00", 18, 10, 25.2),
            response("11:00", 36),
            response("14:00", 360, 90),
          ],
        },
      });
    };
    expect(await fetchWind("test-token", url, fetcher, now)).toEqual({
      v: 1,
      status: "ok",
      source: "weatherkit",
      directionDeg: 0,
      speedMps: 6.67,
      gustMps: 7,
      fetchedAt: now,
      samples: [
        { t: Date.parse("2022-01-01T09:00:00Z"), speedMps: 5, directionDeg: 350, gustMps: null },
        { t: Date.parse("2022-01-01T10:00:00Z"), speedMps: 5, directionDeg: 10, gustMps: 7 },
        { t: Date.parse("2022-01-01T11:00:00Z"), speedMps: 10, directionDeg: null, gustMps: null },
      ],
    });
  });

  it.each([429, 502])("retries HTTP %s", async (status) => {
    await expect(
      fetchWind("test-token", url, async () => new Response("", { status }), now),
    ).rejects.toThrow(WindTransientError);
  });

  it("retries network errors during fetch and while reading the response", async () => {
    const offline = async () => {
      throw new TypeError("network");
    };
    const brokenBody = async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            controller.error(new TypeError("connection lost"));
          },
        }),
      );
    for (const fetcher of [offline, brokenBody]) {
      await expect(fetchWind("test-token", url, fetcher, now)).rejects.toThrow(WindTransientError);
    }
  });

  it.each([400, 401, 403, 404])("stores HTTP %s as permanently unavailable", async (status) => {
    expect(
      await fetchWind("test-token", url, async () => new Response("", { status }), now),
    ).toEqual({
      v: 1,
      status: "unavailable",
      reason: `http_${status}`,
      fetchedAt: now,
    });
  });

  it("classifies invalid credentials, malformed responses and missing hours as permanent", async () => {
    const fetcher = vi.fn<typeof fetch>(async () => Response.json({}));
    expect(await weatherKitToken({ ...credentials, privateKey: "malformed" }, now)).toBeNull();
    expect(await fetchWind("test-token", url, fetcher, now)).toMatchObject({
      status: "unavailable",
      reason: "no_data",
    });
    expect(
      await fetchWind(
        "test-token",
        url,
        async () => Response.json({ forecastHourly: { hours: 1 } }),
        now,
      ),
    ).toMatchObject({ status: "unavailable", reason: "unexpected_response" });
  });
});
