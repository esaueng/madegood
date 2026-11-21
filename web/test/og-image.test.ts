import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/server/app";
import { privacyZones, sessions, users } from "../src/server/db/schema";
import { ogFingerprint } from "../src/server/lib/og-image";
import { arcClearsZones } from "../src/server/lib/session-privacy";
import { userPrefix } from "../src/server/lib/storage";
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
async function processedSession(fixes = lineFixes(), zonesVersion = 0, encode = JSON.stringify) {
  const owner = await signIn();
  const id = crypto.randomUUID();
  const prefix = `${userPrefix(owner.user.id)}sessions/${id}/`;
  const trackKey = `${prefix}track.v1.gz`;
  const object = await env.TRACKS.put(trackKey, await gzip(encode(track(id, fixes))));
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
  return { id, prefix, trackKey, fingerprint, owner, path: imagePath(id, fingerprint) };
}

const imagePath = (id: string, fingerprint: string) => `/s/${id}/og.png?v=${fingerprint}`;

const assets = {
  fetch: async () => new Response(SHELL, { headers: { "content-type": "text/html" } }),
};

async function get(
  path: string,
  headers: Record<string, string> = {},
  bindings: Partial<Env> = {},
) {
  const ctx = createExecutionContext();
  const response = await sessionPreviewPage.request(
    new URL(path, ORIGIN),
    { headers },
    { ...env, ASSETS: assets, ...bindings },
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

async function expectBrand(response: Response) {
  expect(response.status).toBe(302);
  expect(Object.fromEntries(response.headers)).toEqual({
    location: "/og-default.png",
    "cache-control": "no-store",
  });
  expect(await response.text()).toBe("");
}

async function cachedImage(path: string) {
  return caches.default.match(new URL(path, ORIGIN).href);
}

async function seedCache(path: string) {
  const response = await get(path);
  expect(response.status).toBe(200);
  await response.body?.cancel();
  const cached = await cachedImage(path);
  expect(cached?.headers.get("cache-control")).toBe("public, max-age=300");
  await cached?.body?.cancel();
}

async function waitFor<T>(probe: () => Promise<T | null | undefined | false>): Promise<T> {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

const ogImageTag = (html: string) =>
  html.match(/property="og:image" content="([^"]+)"/)?.[1] ?? null;

describe("public reads while account deletion is blocked", () => {
  it.each(["public", "unlisted"] as const)(
    "serves the unknown-resource response even while a %s session and its track still exist",
    async (visibility) => {
      const { id, owner, fingerprint, path, trackKey } = await processedSession();
      if (visibility === "unlisted") {
        expect(
          (await api(`/sessions/${id}`, json("PATCH", { visibility }, owner.accessToken))).status,
        ).toBe(200);
      }
      await seedCache(path);
      const app = createApp();
      const bindings = { ...env, ASSETS: assets };
      const request = (path: string, init?: RequestInit, db = env.DB) =>
        app.request(new URL(path, ORIGIN), init, { ...bindings, DB: db }, createExecutionContext());
      const unknownId = crypto.randomUUID();
      const enabled = await api(
        "/me",
        json(
          "PATCH",
          { publicProfileEnabled: true, displayName: "Test Skipper" },
          owner.accessToken,
        ),
      );
      expect(enabled.status).toBe(200);
      const { publicProfileKey } = (await enabled.json()) as { publicProfileKey: string };
      const profile = `/u/${publicProfileKey}`;
      const sessionPage = `/s/${id}`;
      const paths = [
        [`/api/sessions/${id}`, `/api/sessions/${unknownId}`, 200],
        [`/api/sessions/${id}/track`, `/api/sessions/${unknownId}/track`, 200],
        [sessionPage, `/s/${unknownId}`, 200],
        [path, imagePath(unknownId, fingerprint), 200],
        [profile, `/u/${unknownId}`, 200],
        [
          `/api/users/${publicProfileKey}`,
          `/api/users/${unknownId}`,
          visibility === "public" ? 200 : 404,
        ],
      ] as const;
      for (const [url, , status] of paths) {
        const response = await request(url);
        expect(response.status, url).toBe(status);
        if (url === sessionPage) {
          expect(ogImageTag(await response.text())).toBe(`${ORIGIN}${path}`);
        } else if (url === profile && visibility === "public") {
          expect(await response.text()).toContain("Test Skipper");
        } else {
          await response.body?.cancel();
        }
      }

      let batches = 0;
      const blocked = new Proxy(env.DB, {
        get(target, property) {
          if (property === "batch") {
            return (statements: D1PreparedStatement[]) =>
              ++batches === 2
                ? Promise.reject(new Error("Synthetic purge failure"))
                : target.batch(statements);
          }
          const value = Reflect.get(target, property);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      const deletion = await request(
        "/api/me",
        json("DELETE", { userId: owner.user.id }, owner.accessToken),
        blocked,
      );
      expect(deletion.status).toBe(202);
      const db = drizzle(env.DB);
      const [account] = await db.select().from(users).where(eq(users.id, owner.user.id));
      expect(account?.deletedAt).toEqual(expect.any(Number));
      expect(account?.deletionAttempts).toBe(1);
      const [session] = await db.select().from(sessions).where(eq(sessions.id, id));
      expect(session).toMatchObject({ deletedAt: null, trackKey, visibility });
      expect(await env.TRACKS.head(trackKey)).not.toBeNull();

      for (const [url, unknownUrl] of paths) {
        const init =
          url === path ? { headers: { "if-none-match": `"${fingerprint}"` } } : undefined;
        const actual = await request(url, init);
        const unknown = await request(unknownUrl, init);
        expect(actual.status, url).toBe(unknown.status);
        expect(Object.fromEntries(actual.headers), url).toEqual(
          Object.fromEntries(unknown.headers),
        );
        // Generic pages still echo their own URL in og:url.
        expect(
          (await actual.text()).replace(`${ORIGIN}${url}"`, `${ORIGIN}${unknownUrl}"`),
          url,
        ).toBe(await unknown.text());
      }
    },
  );
});

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
    const runs = lineFixes(2_049).map((fix) => [fix]);
    expect(projectRoute(runs.slice(0, 2_048)).runs.flat()).toHaveLength(2_048);
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
  it("renders inline, uses the edge cache on a hit, and leaves only the source track in R2", async () => {
    const { path, prefix, trackKey, fingerprint } = await processedSession();
    const etag = `"${fingerprint}"`;
    const read = vi.fn((key: string) => env.TRACKS.get(key));
    const write = vi.fn(() => {
      throw new Error("Unexpected R2 write");
    });
    const bindings = { TRACKS: { get: read, put: write } as unknown as R2Bucket };
    const first = await get(path, {}, bindings);
    expect(first.status).toBe(200);
    expect(first.headers.get("cache-control")).toBe("public, max-age=0, must-revalidate");
    expect(first.headers.get("content-type")).toBe("image/png");
    expect(first.headers.get("etag")).toBe(etag);
    const bytes = await first.arrayBuffer();
    expect(pngSize(new Uint8Array(bytes))).toEqual({ width: CARD_WIDTH, height: CARD_HEIGHT });

    const second = await get(`${path}&ignored=1`, {}, bindings);
    expect(second.status).toBe(200);
    expect(await second.arrayBuffer()).toEqual(bytes);
    const conditional = await get(path, { "if-none-match": `"old", W/${etag}` }, bindings);
    expect(conditional.status).toBe(304);
    expect(conditional.headers.get("cache-control")).toBe("public, max-age=0, must-revalidate");
    expect(conditional.headers.get("etag")).toBe(etag);
    expect(conditional.body).toBeNull();
    expect(read.mock.calls).toEqual([[trackKey]]);
    expect(write).not.toHaveBeenCalled();
    expect((await env.TRACKS.list({ prefix })).objects.map((object) => object.key)).toEqual([
      trackKey,
    ]);
  });

  it.each(["private", "deleted", "account-deleting", "stale"] as const)(
    "returns the unknown-ID response for a %s request even with a cached PNG and matching ETag",
    async (change) => {
      const { id, owner, fingerprint, path } = await processedSession();
      await seedCache(path);
      const db = drizzle(env.DB);
      if (change === "private") {
        const patch = json("PATCH", { visibility: "private" }, owner.accessToken);
        expect((await api(`/sessions/${id}`, patch)).status).toBe(200);
        expect(ogImageTag(await (await get(`/s/${id}`)).text())).toBe(`${ORIGIN}/og-default.png`);
      } else if (change === "deleted") {
        const deleted = await api(`/sessions/${id}`, {
          method: "DELETE",
          headers: bearer(owner.accessToken),
        });
        expect(deleted.status).toBe(204);
      } else {
        await db
          .update(users)
          .set(change === "account-deleting" ? { deletedAt: Date.now() } : { units: "metric" })
          .where(eq(users.id, owner.user.id));
      }

      const cache = caches.default;
      const match = vi.spyOn(cache, "match");
      try {
        await expectBrand(await get(path));
        await expectBrand(await get(path, { "if-none-match": `"${fingerprint}"` }));
        expect(match).not.toHaveBeenCalled();
      } finally {
        match.mockRestore();
      }
      const cached = await cachedImage(path);
      expect(cached?.status).toBe(200);
      await cached?.body?.cancel();
    },
  );

  it.each(["body", "304"] as const)(
    "rechecks eligibility before returning a cached %s",
    async (kind) => {
      const { id, fingerprint, path } = await processedSession();
      await seedCache(path);
      const cache = caches.default;
      const originalMatch = cache.match.bind(cache);
      const match = vi.spyOn(cache, "match").mockImplementation(async (key) => {
        const hit = await originalMatch(key);
        expect(hit?.status).toBe(200);
        await drizzle(env.DB)
          .update(sessions)
          .set({ visibility: "private" })
          .where(eq(sessions.id, id));
        return hit;
      });
      try {
        await expectBrand(
          await get(path, kind === "304" ? { "if-none-match": `"${fingerprint}"` } : {}),
        );
        expect(match).toHaveBeenCalledOnce();
      } finally {
        match.mockRestore();
      }
    },
  );

  it.each(["body", "304"] as const)(
    "rejects a cold %s if the track changes during rendering",
    async (kind) => {
      const { id, fingerprint, path } = await processedSession();
      const read = vi.fn(async (key: string) => {
        const object = await env.TRACKS.get(key);
        await drizzle(env.DB)
          .update(sessions)
          .set({ uploadRevision: 1, trackEtag: "trimmed", processedEtag: "trimmed" })
          .where(eq(sessions.id, id));
        return object;
      });
      const headers: Record<string, string> =
        kind === "304" ? { "if-none-match": `"${fingerprint}"` } : {};
      await expectBrand(await get(path, headers, { TRACKS: { get: read } as unknown as R2Bucket }));
      expect(read).toHaveBeenCalledOnce();
      expect(await cachedImage(path)).toBeUndefined();
    },
  );

  it("treats missing fingerprints and unknown or malformed IDs like the brand fallback", async () => {
    const { id, fingerprint } = await processedSession();
    for (const path of [
      `/s/${id}/og.png`,
      imagePath(crypto.randomUUID(), fingerprint),
      imagePath("not-a-uuid", fingerprint),
    ]) {
      await expectBrand(await get(path, { "if-none-match": `"${fingerprint}"` }));
    }
  });

  it.each([
    { limit: "fix count", fixes: 20_001, padding: 0 },
    { limit: "inflated payload size", fixes: 100, padding: 2 * 1024 * 1024 },
  ])("falls back above the $limit cap", async ({ fixes, padding }) => {
    const { fingerprint, path } = await processedSession(
      lineFixes(fixes),
      0,
      (document) => JSON.stringify(document) + " ".repeat(padding),
    );
    await expectBrand(await get(path, { "if-none-match": `"${fingerprint}"` }));
    expect(await cachedImage(path)).toBeUndefined();
  });

  it("draws exactly the fixes outside privacy zones, with a gap across each zone", async () => {
    const zone = { lat: 500 * DEG_PER_M, lon: 0, radiusM: 150 };
    const fixes = lineFixes();
    const { owner, path } = await processedSession(fixes, 1);
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
    const response = await get(path);
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

  it("never serves a previous owner's image or ETag for a reused session ID", async () => {
    // Regression (PR #96 review): zones versions are per account, so the same session ID,
    // track bytes and zones version under another account must not match the old image.
    const { id, path, fingerprint } = await processedSession();
    await seedCache(path);
    const next = await signIn();
    await drizzle(env.DB).update(sessions).set({ userId: next.user.id }).where(eq(sessions.id, id));
    await expectBrand(await get(path));
    await expectBrand(await get(path, { "if-none-match": `"${fingerprint}"` }));
    const [moved] = await drizzle(env.DB).select().from(sessions).where(eq(sessions.id, id));
    if (!moved) throw new Error("missing test session");
    expect(await ogFingerprint(moved, "nautical", 0)).not.toBe(fingerprint);
  });

  it("redraws the image under a new URL when a zone is added", async () => {
    const owner = await signIn();
    const id = await shareSession(owner, lineFixes(), "unlisted");
    const imageTag = async () => ogImageTag(await (await get(`/s/${id}`)).text());
    const firstTag = await waitFor(async () => {
      const tag = await imageTag();
      return tag?.includes("/og.png?v=") ? tag : null;
    });
    const first = await get(firstTag);
    expect(first.status).toBe(200);
    const firstBytes = await first.arrayBuffer();

    const zone = { lat: 500 * DEG_PER_M, lon: 0, radiusM: 150 };
    expect((await api("/me/privacy-zones", json("POST", zone, owner.accessToken))).status).toBe(
      201,
    );
    const secondTag = await waitFor(async () => {
      const tag = await imageTag();
      return tag !== firstTag && tag?.includes("/og.png?v=") ? tag : null;
    });
    await expectBrand(await get(firstTag));
    const second = await get(secondTag);
    expect(second.status).toBe(200);
    expect(
      new Uint8Array(await crypto.subtle.digest("SHA-256", await second.arrayBuffer())),
    ).not.toEqual(new Uint8Array(await crypto.subtle.digest("SHA-256", firstBytes)));
  });

  it("puts the image, its size and alt text in the tags", async () => {
    const { id } = await processedSession();
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
