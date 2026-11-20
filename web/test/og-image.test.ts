import { env } from "cloudflare:workers";
import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { describe, expect, it } from "vitest";
import { privacyZones, sessions, users } from "../src/server/db/schema";
import { ogFingerprint, ogImageKey, syncOgImage } from "../src/server/lib/og-image";
import { processMessage } from "../src/server/lib/postprocess";
import { collectR2Garbage, UPLOAD_GRACE_MS } from "../src/server/lib/r2-garbage";
import { arcClearsZones } from "../src/server/lib/session-privacy";
import { distanceM, ZONE_MARGIN_M } from "../src/server/lib/voyage-sharing";
import {
  CARD_HEIGHT,
  CARD_WIDTH,
  type LatLon,
  projectRoute,
  ROUTE_BOX,
  routeCardSvg,
  routeRuns,
} from "../src/server/og/card";
import { svgToPng } from "../src/server/og/render";
import { sessionPreviewPage } from "../src/server/routes/session-preview";
import { api, bearer, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.
const START = "2000-01-01T10:00:00.000Z";
const DEG_PER_M = 1 / 111_195;
const SHELL =
  '<!doctype html><html><head><meta name="description" content="Default" /><title>MadeGood</title></head><body><div id="root"></div></body></html>';
const ORIGIN = "https://madegood.test";

const json = (method: string, body: unknown, token: string) => ({
  method,
  headers: { ...bearer(token), "content-type": "application/json" },
  body: JSON.stringify(body),
});

/** A northbound line from 0,0: one fix per second, 10 m apart. */
function lineFixes(seconds = 100): LatLon[] {
  return Array.from({ length: seconds }, (_, i) => ({
    lat: Number((i * 10 * DEG_PER_M).toFixed(7)),
    lon: 0,
  }));
}

function track(id: string, fixes: LatLon[]) {
  const t = fixes.map((_, i) => i);
  return {
    v: 1,
    sessionId: id,
    sport: "kayak",
    startedAt: START,
    gps: {
      t,
      lat: fixes.map((f) => f.lat),
      lon: fixes.map((f) => f.lon),
      spd: t.map(() => 10),
      crs: t.map(() => 0),
      hacc: t.map(() => 4),
    },
    hr: { t: [], bpm: [] },
    events: [],
  };
}

async function gzip(text: string) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const META = { sport: "kayak", startedAt: START, durationS: 3725, distanceM: 990 };

async function shareSession(owner: SignIn, fixes: LatLon[], visibility = "public") {
  const id = crypto.randomUUID();
  expect((await api(`/sessions/${id}`, json("PUT", META, owner.accessToken))).status).toBe(201);
  const upload = await api(`/sessions/${id}/track`, {
    method: "PUT",
    headers: { ...bearer(owner.accessToken), "content-type": "application/gzip" },
    body: await gzip(JSON.stringify(track(id, fixes))),
  });
  expect(upload.status).toBe(204);
  const patch = json("PATCH", { visibility }, owner.accessToken);
  expect((await api(`/sessions/${id}`, patch)).status).toBe(200);
  return id;
}

/** Set up an already-processed track without a queue consumer racing the test. */
async function processedSession(fixes = lineFixes(), zonesVersion = 0) {
  const owner = await signIn();
  const id = crypto.randomUUID();
  const key = ogImageKey(owner.user.id, id);
  const trackKey = key.replace(/og\.png$/, "track.v1.gz");
  const object = await env.TRACKS.put(trackKey, await gzip(JSON.stringify(track(id, fixes))));
  if (!object) throw new Error("missing test track");
  const [session] = await drizzle(env.DB)
    .insert(sessions)
    .values({
      ...META,
      sport: "kayak",
      startedAt: Date.parse(START),
      id,
      userId: owner.user.id,
      visibility: "public",
      trackKey,
      trackEtag: object.etag,
      processedEtag: object.etag,
      postprocessStatus: "done",
      publicMinLat: 0,
      publicZonesVersion: zonesVersion,
    })
    .returning();
  if (!session) throw new Error("missing test session");
  const fingerprint = await ogFingerprint(session, "nautical", zonesVersion);
  return { id, key, trackKey, fingerprint, owner };
}

function bucket(overrides: Partial<R2Bucket>): R2Bucket {
  return {
    get: env.TRACKS.get.bind(env.TRACKS),
    head: env.TRACKS.head.bind(env.TRACKS),
    put: env.TRACKS.put.bind(env.TRACKS),
    delete: env.TRACKS.delete.bind(env.TRACKS),
    list: env.TRACKS.list.bind(env.TRACKS),
    ...overrides,
  } as R2Bucket;
}

const assets = {
  fetch: async () => new Response(SHELL, { headers: { "content-type": "text/html" } }),
};
const get = (path: string, headers: Record<string, string> = {}, bindings: Partial<Env> = {}) =>
  sessionPreviewPage.request(
    `${ORIGIN}${path}`,
    { headers },
    { ...env, ASSETS: assets, ...bindings },
  );

async function waitFor<T>(probe: () => Promise<T | null | undefined | false>): Promise<T> {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

/** The session's image once post-processing made it available. */
const imageOf = (id: string) =>
  waitFor(async () => {
    const response = await get(`/s/${id}/og.png`);
    if (response.status === 200) return response;
    await response.body?.cancel();
    return null;
  });

const ogImageTag = (html: string) =>
  html.match(/property="og:image" content="([^"]+)"/)?.[1] ?? null;

const stored = async (id: string) => {
  const [row] = await drizzle(env.DB)
    .select({ userId: sessions.userId })
    .from(sessions)
    .where(eq(sessions.id, id));
  if (!row) throw new Error("no row");
  return env.TRACKS.head(ogImageKey(row.userId, id));
};

function pngSize(bytes: Uint8Array) {
  const view = new DataView(bytes.buffer, bytes.byteOffset);
  expect(Array.from(bytes.slice(1, 4), (b) => String.fromCharCode(b)).join("")).toBe("PNG");
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

function ends(route: ReturnType<typeof projectRoute>): [[number, number], [number, number]] {
  if (!route.start || !route.end) throw new Error("no route");
  return [route.start, route.end];
}

describe("route geometry", () => {
  it("breaks the line at every privacy gap", () => {
    const runs = routeRuns([0, 1, 2, 3, 4], [0, 0, 0, 0, 0], [2, 4]);
    expect(runs.map((run) => run.map((p) => p.lat))).toEqual([[0, 1], [2, 3], [4]]);
  });

  it("fits the route north up inside the route box", () => {
    const route = projectRoute([lineFixes()]);
    const points = route.runs.flat();
    for (const [x, y] of points) {
      expect(x).toBeGreaterThanOrEqual(ROUTE_BOX.x - 0.01);
      expect(x).toBeLessThanOrEqual(ROUTE_BOX.x + ROUTE_BOX.width + 0.01);
      expect(y).toBeGreaterThanOrEqual(ROUTE_BOX.y - 0.01);
      expect(y).toBeLessThanOrEqual(ROUTE_BOX.y + ROUTE_BOX.height + 0.01);
    }
    // Northbound: the end is above the start, and the line spans the box's height.
    expect(route.end?.[1]).toBeCloseTo(ROUTE_BOX.y, 1);
    expect(route.start?.[1]).toBeCloseTo(ROUTE_BOX.y + ROUTE_BOX.height, 1);
  });

  it("draws a route across the antimeridian the short way round", () => {
    // About 2.2 km east and 2.2 km north, crossing 180°.
    const route = projectRoute([
      [
        { lat: 10, lon: 179.99 },
        { lat: 10.02, lon: -179.99 },
      ],
    ]);
    const [start, end] = ends(route);
    expect(Math.abs(end[0] - start[0])).toBeGreaterThan(300);
    expect(Math.abs(end[1] - start[1])).toBeGreaterThan(300);
  });

  it("keeps a subpixel detour when a shortcut would cross a zone", () => {
    const fix = (x: number, y: number) => ({ lat: y * DEG_PER_M, lon: x * DEG_PER_M });
    const zones = [{ ...fix(0, 0), radiusM: 20 }];
    const before = fix(-50, 0);
    const entry = fix(-50, 70);
    const exit = fix(50, 70);
    const after = fix(50, 0);
    const canJoin = (a: LatLon, b: LatLon) => arcClearsZones(a, b, zones);
    expect(canJoin(before, entry)).toBe(true);
    expect(canJoin(entry, exit)).toBe(true);
    expect(canJoin(exit, after)).toBe(true);
    expect(canJoin(before, after)).toBe(false);
    // A distant run sets the scale, putting the entire detour below the thinning threshold.
    const route = projectRoute(
      [[before, entry, exit, after], [fix(150_000, 0)]],
      ROUTE_BOX,
      canJoin,
    );
    expect(route.runs[0]).toHaveLength(4);
  });

  it("falls back when the route cannot fit the point budget without joining gaps", () => {
    const runs = lineFixes(3_000).map((fix) => [fix]);
    expect(projectRoute(runs).start).toBeNull();
  });

  it("keeps GPS jitter at a mooring small", () => {
    const route = projectRoute([
      [
        { lat: 0, lon: 0 },
        { lat: 3 * DEG_PER_M, lon: 0 },
      ],
    ]);
    const [start, end] = ends(route);
    expect(Math.abs(end[1] - start[1])).toBeLessThan(10);
  });
});

describe("Open Graph route images", () => {
  it.each(["private", "zone", "trim", "owner"] as const)(
    "rechecks a cache hit when %s changes during the R2 read",
    async (change) => {
      const { id, key, fingerprint, owner } = await processedSession();
      await env.TRACKS.put(key, "old route", { customMetadata: { fp: fingerprint } });
      const revoke = async () => {
        if (change === "zone" || change === "owner") {
          await drizzle(env.DB)
            .update(users)
            .set(change === "zone" ? { zonesVersion: 1 } : { deletedAt: Date.now() })
            .where(eq(users.id, owner.user.id));
        } else {
          await drizzle(env.DB)
            .update(sessions)
            .set(
              change === "private"
                ? { visibility: "private" }
                : { uploadRevision: 1, trackEtag: "trimmed", processedEtag: "trimmed" },
            )
            .where(eq(sessions.id, id));
        }
      };
      const storage = bucket({
        async get(name) {
          const hit = await env.TRACKS.get(name);
          await revoke();
          return hit;
        },
        async head(name) {
          const hit = await env.TRACKS.head(name);
          await revoke();
          return hit;
        },
      });
      // Exercise both the body and conditional paths with the matching old fingerprint.
      const headers: Record<string, string> =
        change === "zone" || change === "trim" ? { "if-none-match": `"${fingerprint}"` } : {};
      const response = await get(`/s/${id}/og.png`, headers, { TRACKS: storage });
      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toBe("/og-default.png");
    },
  );

  it("rejects a render when the track is trimmed during its R2 write", async () => {
    const { id } = await processedSession();
    const storage = bucket({
      async put(name, value, options) {
        const result = await env.TRACKS.put(name, value, options);
        await drizzle(env.DB)
          .update(sessions)
          .set({ uploadRevision: 1, trackEtag: "trimmed", processedEtag: "trimmed" })
          .where(eq(sessions.id, id));
        return result;
      },
    });
    expect(await syncOgImage({ DB: env.DB, TRACKS: storage }, id)).not.toBe("current");
  });

  it("collects a late write after the session delete and immediate R2 cleanup failure", async () => {
    const { id, key, owner } = await processedSession();
    const storage = bucket({
      async put(name, value, options) {
        expect(name).toBe(key);
        const deleted = await api(`/sessions/${id}`, {
          method: "DELETE",
          headers: bearer(owner.accessToken),
        });
        expect(deleted.status).toBe(204);
        expect(await env.TRACKS.head(key)).toBeNull();
        return env.TRACKS.put(name, value, options);
      },
      async delete() {
        throw new Error("transient R2 failure");
      },
    });
    await expect(syncOgImage({ DB: env.DB, TRACKS: storage }, id)).rejects.toThrow(
      "transient R2 failure",
    );
    expect(await env.TRACKS.head(key)).not.toBeNull();
    // Age the record past the upload grace and claim lease, as on a later cron pass.
    await env.DB.prepare(
      "UPDATE pending_r2_deletes SET created_at = 0, claimed_at = 0 WHERE key = ?",
    )
      .bind(key)
      .run();
    await collectR2Garbage(drizzle(env.DB), env.TRACKS, {
      userId: owner.user.id,
      before: Date.now() - UPLOAD_GRACE_MS,
    });
    expect(await env.TRACKS.head(key)).toBeNull();
  });

  it("serves the brand fallback on cold requests without fetching the track", async () => {
    const { id, key: imageKey } = await processedSession();
    const reads: string[] = [];
    const storage = bucket({
      async get(key) {
        reads.push(key);
        return env.TRACKS.get(key);
      },
    });
    const path = `/s/${id}/og.png`;
    const messages: unknown[] = [];
    const bindings = {
      TRACKS: storage,
      POSTPROCESS: {
        async send(message: unknown) {
          messages.push(message);
          return { metadata: { metrics: { backlogCount: messages.length, backlogBytes: 0 } } };
        },
        metrics: async () => {
          throw new Error("unexpected queue metrics request");
        },
        sendBatch: async () => {
          throw new Error("unexpected queue batch");
        },
      },
    };
    const results = await Promise.all([get(path, {}, bindings), get(path, {}, bindings)]);
    expect(results.map((res) => res.status)).toEqual([302, 302]);
    expect(reads).toEqual([imageKey, imageKey]);
    expect(messages).toContainEqual({ v: 1, kind: "og", sessionId: id });
    await processMessage(env, messages[0]);
    const refreshed = await get(path);
    expect(refreshed.status).toBe(200);
    await refreshed.body?.cancel();
  });

  it("remembers an over-budget route and keeps serving the brand fallback", async () => {
    const { id, key } = await processedSession(lineFixes(20_001));
    const path = `/s/${id}/og.png`;
    await syncOgImage(env, id);
    expect((await env.TRACKS.head(key))?.size).toBe(0);
    expect((await get(path)).status).toBe(302);
  });

  it("lets only one overlapping producer read and render the track", async () => {
    const { id, trackKey } = await processedSession();
    let trackReads = 0;
    let duplicate: Awaited<ReturnType<typeof syncOgImage>> | undefined;
    const storage = bucket({
      async get(key) {
        if (key === trackKey && ++trackReads === 1) {
          duplicate = await syncOgImage({ DB: env.DB, TRACKS: storage }, id);
        }
        return env.TRACKS.get(key);
      },
    });
    expect(await syncOgImage({ DB: env.DB, TRACKS: storage }, id)).toBe("current");
    expect(duplicate).not.toBe("current");
    expect(trackReads).toBe(1);
  });

  it("draws exactly the fixes outside privacy zones, with a gap across each zone", async () => {
    const zone = { lat: 500 * DEG_PER_M, lon: 0, radiusM: 150 };
    const fixes = lineFixes();
    const { id, owner } = await processedSession(fixes, 1);
    await drizzle(env.DB).batch([
      drizzle(env.DB).update(users).set({ zonesVersion: 1 }).where(eq(users.id, owner.user.id)),
      drizzle(env.DB)
        .insert(privacyZones)
        .values({
          id: crypto.randomUUID(),
          userId: owner.user.id,
          ...zone,
        }),
    ]);
    expect(await syncOgImage(env, id)).toBe("current");
    const response = await get(`/s/${id}/og.png`);
    expect(response.status).toBe(200);
    const served = new Uint8Array(await response.arrayBuffer());
    expect(pngSize(served)).toEqual({ width: CARD_WIDTH, height: CARD_HEIGHT });

    // The same card drawn by hand from the fixes outside the zone, as two separate runs.
    const outside = (f: LatLon) => distanceM(zone, f) > zone.radiusM + ZONE_MARGIN_M;
    const before = fixes.filter((f, i) => outside(f) && i < 50);
    const after = fixes.filter((f, i) => outside(f) && i >= 50);
    expect(before.length + after.length).toBeLessThan(fixes.length - 25);
    const card = { sport: "kayak", units: "nautical", distanceM: 990, durationS: 3725 } as const;
    const expected = await svgToPng(
      routeCardSvg({ ...card, route: projectRoute([before, after]) }),
    );
    const hash = async (bytes: Uint8Array) =>
      new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    const servedHash = await hash(served);
    expect(servedHash).toEqual(await hash(expected));
    // And not the card of the whole line.
    const whole = await svgToPng(routeCardSvg({ ...card, route: projectRoute([fixes]) }));
    expect(servedHash).not.toEqual(await hash(whole));
  });

  it("gives private sessions no image and only the brand card in the tags", async () => {
    const owner = await signIn();
    const id = await shareSession(owner, lineFixes(), "private");
    // Processed, still nothing: the route answers like it does for an unknown session.
    await waitFor(async () => {
      const response = await api(`/sessions/${id}`, { headers: bearer(owner.accessToken) });
      return ((await response.json()) as { processing: string }).processing === "done";
    });
    for (const target of [id, crypto.randomUUID(), "not-a-uuid"]) {
      const response = await get(`/s/${target}/og.png`);
      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toBe("/og-default.png");
      expect(response.headers.get("cache-control")).toBe("no-store");
    }
    expect(await stored(id)).toBeNull();
    const html = await (await get(`/s/${id}`)).text();
    expect(ogImageTag(html)).toBe(`${ORIGIN}/og-default.png`);
  });

  it("serves the image while shared and deletes it once the session is private", async () => {
    const owner = await signIn();
    const id = await shareSession(owner, lineFixes(), "unlisted");
    const response = await imageOf(id);
    expect(response.headers.get("content-type")).toBe("image/png");
    expect(response.headers.get("cache-control")).toBe("no-cache");
    const etag = response.headers.get("etag") as string;
    await response.body?.cancel();
    const revalidated = await get(`/s/${id}/og.png`, { "if-none-match": etag });
    expect(revalidated.status).toBe(304);
    expect(await stored(id)).not.toBeNull();

    const html = await (await get(`/s/${id}`)).text();
    expect(ogImageTag(html)).toBe(`${ORIGIN}/s/${id}/og.png?v=${etag.replaceAll('"', "")}`);

    const patch = json("PATCH", { visibility: "private" }, owner.accessToken);
    expect((await api(`/sessions/${id}`, patch)).status).toBe(200);
    expect((await get(`/s/${id}/og.png`)).status).toBe(302);
    await waitFor(async () => (await stored(id)) === null);
    expect(ogImageTag(await (await get(`/s/${id}`)).text())).toBe(`${ORIGIN}/og-default.png`);
  });

  it("redraws the image under a new URL when a zone is added", async () => {
    const owner = await signIn();
    const id = await shareSession(owner, lineFixes());
    const first = await imageOf(id);
    const firstTag = ogImageTag(await (await get(`/s/${id}`)).text());
    const firstBytes = new Uint8Array(await first.arrayBuffer());

    // Mid-line, so the redrawn line has a gap (cutting an end off a straight line would
    // refit to the same picture).
    const zone = { lat: 500 * DEG_PER_M, lon: 0, radiusM: 150 };
    await api("/me/privacy-zones", json("POST", zone, owner.accessToken));
    const secondTag = await waitFor(async () => {
      const tag = ogImageTag(await (await get(`/s/${id}`)).text());
      return tag !== firstTag && tag?.includes("/og.png?v=") ? tag : null;
    });
    expect(secondTag).not.toBe(firstTag);
    const second = new Uint8Array(await (await imageOf(id)).arrayBuffer());
    expect(new Uint8Array(await crypto.subtle.digest("SHA-256", second))).not.toEqual(
      new Uint8Array(await crypto.subtle.digest("SHA-256", firstBytes)),
    );
  });

  it("deletes the image with the session", async () => {
    const owner = await signIn();
    const id = await shareSession(owner, lineFixes());
    await (await imageOf(id)).body?.cancel();
    const key = ogImageKey(owner.user.id, id);
    expect(await env.TRACKS.head(key)).not.toBeNull();
    await api(`/sessions/${id}`, { method: "DELETE", headers: bearer(owner.accessToken) });
    expect(await env.TRACKS.head(key)).toBeNull();
  });

  it("puts the image, its size and alt text in the tags", async () => {
    const owner = await signIn();
    const id = await shareSession(owner, lineFixes());
    await (await imageOf(id)).body?.cancel();
    const html = await (await get(`/s/${id}`)).text();
    const image = ogImageTag(html);
    expect(image).toMatch(new RegExp(`^${ORIGIN}/s/${id}/og\\.png\\?v=[0-9a-f]{16}$`));
    expect(html).toContain('property="og:image:type" content="image/png"');
    expect(html).toContain('property="og:image:width" content="1200"');
    expect(html).toContain('property="og:image:height" content="630"');
    const alt = "Route map of a kayak session: 0.53 nm in 1 h 02 min";
    expect(html).toContain(`property="og:image:alt" content="${alt}"`);
    expect(html).toContain('name="twitter:card" content="summary_large_image"');
    expect(html).toContain(`name="twitter:image" content="${image}"`);
    expect(html).toContain(`name="twitter:image:alt" content="${alt}"`);
  });
});
