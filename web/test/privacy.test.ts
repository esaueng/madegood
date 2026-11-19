import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { PRIVACY_GAP_EVENT, shareTrack } from "../src/server/lib/session-privacy";
import { MAX_ZONES } from "../src/server/routes/privacy-zones";
import { injectPreview, sessionPreviewPage } from "../src/server/routes/session-preview";
import { api, bearer, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.
const START = "2000-01-01T10:00:00.000Z";
/** About 111 m of latitude per 0.001°. */
const DEG_PER_M = 1 / 111_195;

const json = (method: string, body: unknown, token: string) => ({
  method,
  headers: { ...bearer(token), "content-type": "application/json" },
  body: JSON.stringify(body),
});

const addZone = (token: string, zone: unknown) =>
  api("/me/privacy-zones", json("POST", zone, token));

/** A northbound line from 0,0: one fix per second, 10 m apart, with heart rate and events. */
function lineTrack(id: string, seconds = 100) {
  const t = Array.from({ length: seconds }, (_, i) => i);
  return {
    v: 1,
    sessionId: id,
    sport: "kayak",
    startedAt: START,
    analyzerVersion: "1.1.0",
    gps: {
      t,
      lat: t.map((i) => Number((i * 10 * DEG_PER_M).toFixed(7))),
      lon: t.map(() => 0),
      spd: t.map(() => 10),
      crs: t.map(() => 0),
      hacc: t.map(() => 4),
      alt: t.map(() => 1),
    },
    hr: { t: [0, 50], bpm: [100, 120] },
    events: [
      { t: 5, type: "mark", data: { lat: 0.0001, lon: 0 } },
      { t: 6, type: "mob" },
      { t: 30, type: "tack", data: { durationS: 6, lat: 0.0003, note: "x" } },
      { t: 40, type: "lap" },
    ],
    summary: { distance: 990, heartRateMax: 120, start: { lat: 0, lon: 0 } },
  };
}

async function gzip(text: string) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
async function gunzip(bytes: ArrayBuffer) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).text();
}

async function publicSession(owner: SignIn, track: (id: string) => unknown, visibility = "public") {
  const id = crypto.randomUUID();
  const meta = {
    sport: "kayak",
    startedAt: START,
    durationS: 100,
    movingS: 99,
    distanceM: 990,
    maxSpeedMps: 10,
    summary: { distance: 990, heartRateMax: 120 },
  };
  expect((await api(`/sessions/${id}`, json("PUT", meta, owner.accessToken))).status).toBe(201);
  const upload = await api(`/sessions/${id}/track`, {
    method: "PUT",
    headers: { ...bearer(owner.accessToken), "content-type": "application/gzip" },
    body: await gzip(JSON.stringify(track(id))),
  });
  expect(upload.status).toBe(204);
  const patch = json("PATCH", { visibility, title: "Evening <paddle>" }, owner.accessToken);
  expect((await api(`/sessions/${id}`, patch)).status).toBe(200);
  return id;
}

async function sharedTrack(token: string | null, id: string) {
  const response = await api(`/sessions/${id}/track`, { headers: token ? bearer(token) : {} });
  expect(response.status).toBe(200);
  return JSON.parse(await gunzip(await response.arrayBuffer()));
}

describe("privacy zone API", () => {
  it("adds, lists and removes the caller's own zones", async () => {
    const owner = await signIn();
    const other = await signIn();
    const created = await addZone(owner.accessToken, { lat: 0.001, lon: -0.002, radiusM: 300 });
    expect(created.status).toBe(201);
    const zone = (await created.json()) as { id: string };
    expect(zone).toMatchObject({ lat: 0.001, lon: -0.002, radiusM: 300 });

    const list = (token: string) =>
      api("/me/privacy-zones", { headers: bearer(token) }).then((r) => r.json());
    expect(await list(owner.accessToken)).toEqual({ zones: [zone] });
    expect(await list(other.accessToken)).toEqual({ zones: [] });

    // Another user cannot remove it; the call still answers 204.
    const remove = (token: string) =>
      api(`/me/privacy-zones/${zone.id}`, { method: "DELETE", headers: bearer(token) });
    expect((await remove(other.accessToken)).status).toBe(204);
    expect(await list(owner.accessToken)).toEqual({ zones: [zone] });
    expect((await remove(owner.accessToken)).status).toBe(204);
    expect(await list(owner.accessToken)).toEqual({ zones: [] });
  });

  it("validates zones, caps their number and requires a token", async () => {
    const owner = await signIn();
    for (const bad of [
      { lat: 91, lon: 0, radiusM: 100 },
      { lat: 0, lon: 181, radiusM: 100 },
      { lat: 0, lon: 0, radiusM: 10 },
      { lat: 0, lon: 0, radiusM: 50_000 },
      { lat: 0, lon: 0 },
      { lat: 0, lon: 0, radiusM: 100, userId: "x" },
    ]) {
      expect((await addZone(owner.accessToken, bad)).status).toBe(400);
    }
    for (let i = 0; i < MAX_ZONES; i++) {
      expect(
        (await addZone(owner.accessToken, { lat: i / 100, lon: 0, radiusM: 100 })).status,
      ).toBe(201);
    }
    expect((await addZone(owner.accessToken, { lat: 0, lon: 0, radiusM: 100 })).status).toBe(400);
    expect((await api("/me/privacy-zones")).status).toBe(401);
  });
});

describe("shareTrack", () => {
  const zone = { lat: 0, lon: 0, radiusM: 200 };

  it("removes fixes inside a zone and marks the gap", () => {
    const shared = shareTrack(lineTrack("x"), [zone], { distance: 990 });
    expect(shared).not.toBeNull();
    const gps = shared?.gps as { t: number[]; lat: number[] };
    // Fixes 0–20 lie within 200 m of 0,0.
    expect(gps.t[0]).toBe(21);
    expect(gps.t).toHaveLength(79);
    for (const lat of gps.lat) expect(lat / DEG_PER_M).toBeGreaterThan(200);
  });

  it("breaks the line where an arc between visible fixes could cross a zone", () => {
    // Two fixes 1 km either side of a zone, with nothing in between.
    const track = {
      v: 1,
      gps: {
        t: [0, 1, 2],
        lat: [-1000 * DEG_PER_M, 1000 * DEG_PER_M, 1010 * DEG_PER_M],
        lon: [0, 0, 0],
        spd: [1, 1, 1],
        crs: [0, 0, 0],
        hacc: [4, 4, 4],
      },
      events: [],
    };
    const shared = shareTrack(track, [zone], null) ?? {};
    expect((shared.gps as { t: number[] }).t).toEqual([0, 1, 2]);
    expect(shared.events).toEqual([{ t: 1, type: PRIVACY_GAP_EVENT }]);
    expect(shareTrack(track, [], null)?.events).toEqual([]);
  });

  it("drops heart rate, marks, MOB, free-form event data and optional columns", () => {
    const shared = shareTrack(lineTrack("x"), [], { distance: 990 }) ?? {};
    expect(shared.hr).toEqual({ t: [], bpm: [] });
    expect(shared.events).toEqual([
      { t: 30, type: "tack", data: { durationS: 6 } },
      { t: 40, type: "lap" },
    ]);
    expect(Object.keys(shared.gps as object).sort()).toEqual([
      "crs",
      "hacc",
      "lat",
      "lon",
      "spd",
      "t",
    ]);
    expect(shared.summary).toEqual({ distance: 990 });
  });

  it("rejects documents that are not track v1", () => {
    expect(shareTrack({ v: 2, gps: {} }, [], null)).toBeNull();
    expect(shareTrack("x", [], null)).toBeNull();
  });
});

describe("GET /api/sessions/:id/track with privacy zones", () => {
  it("cuts the owner's zones out for every other viewer", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = await publicSession(owner, lineTrack);
    expect((await addZone(owner.accessToken, { lat: 0, lon: 0, radiusM: 200 })).status).toBe(201);

    for (const token of [other.accessToken, null]) {
      const shared = await sharedTrack(token, id);
      expect(shared.gps.t[0]).toBe(21);
      expect(shared.gps.lat.every((lat: number) => lat / DEG_PER_M > 200)).toBe(true);
      expect(shared.hr).toEqual({ t: [], bpm: [] });
      expect(JSON.stringify(shared)).not.toContain("mark");
      expect(shared.summary).toEqual({ distance: 990 });
    }
    // The owner still gets every fix and the heart rate.
    const mine = await sharedTrack(owner.accessToken, id);
    expect(mine.gps.t).toHaveLength(100);
    expect(mine.hr.bpm).toEqual([100, 120]);
  });

  it("applies a zone added after the upload, and is whole again once it is removed", async () => {
    const owner = await signIn();
    const id = await publicSession(owner, lineTrack, "unlisted");
    expect((await sharedTrack(null, id)).gps.t).toHaveLength(100);
    const zone = (await (
      await addZone(owner.accessToken, { lat: 0, lon: 0, radiusM: 5000 })
    ).json()) as { id: string };
    expect((await sharedTrack(null, id)).gps.t).toEqual([]);
    await api(`/me/privacy-zones/${zone.id}`, {
      method: "DELETE",
      headers: bearer(owner.accessToken),
    });
    expect((await sharedTrack(null, id)).gps.t).toHaveLength(100);
  });

  it("keeps private sessions' tracks from everyone else", async () => {
    const owner = await signIn();
    const id = await publicSession(owner, lineTrack, "private");
    expect((await api(`/sessions/${id}/track`)).status).toBe(404);
  });
});

describe("Open Graph tags on /s/:id", () => {
  const SHELL =
    '<!doctype html><html><head><meta name="description" content="Default" /><title>MadeGood</title></head><body><div id="root"></div></body></html>';
  const assets = {
    fetch: async () => new Response(SHELL, { headers: { "content-type": "text/html" } }),
  };
  const page = async (id: string) => {
    const response = await sessionPreviewPage.request(
      `https://madegood.test/s/${id}`,
      {},
      { ...env, ASSETS: assets },
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-cache");
    return response.text();
  };

  it("previews public and unlisted sessions with title and stats, escaped", async () => {
    const owner = await signIn();
    const id = await publicSession(owner, lineTrack);
    const html = await page(id);
    expect(html).toContain("<title>Evening &lt;paddle&gt; · MadeGood</title>");
    expect(html).toContain('property="og:title" content="Evening &lt;paddle&gt;"');
    // The owner's default units are nautical: 990 m is 0.53 nm, 10 m/s is 19.4 kn.
    expect(html).toContain(
      'property="og:description" content="Kayak · 0.53 nm · 1 min · max 19.4 kn"',
    );
    expect(html).toContain('name="description" content="Kayak · 0.53 nm');
    expect(html).toContain(`property="og:url" content="https://madegood.test/s/${id}"`);
    expect(html).toContain('name="robots" content="index, follow"');
    expect(html).toContain('<div id="root"></div>');

    await api(`/sessions/${id}`, json("PATCH", { visibility: "unlisted" }, owner.accessToken));
    expect(await page(id)).toContain('name="robots" content="noindex"');
  });

  it("never reveals a private, deleted or unknown session, nor any position", async () => {
    const owner = await signIn();
    const id = await publicSession(owner, lineTrack, "private");
    const deleted = await publicSession(owner, lineTrack);
    await api(`/sessions/${deleted}`, { method: "DELETE", headers: bearer(owner.accessToken) });
    const pages = await Promise.all(
      [id, deleted, crypto.randomUUID(), "not-a-uuid"].map((x) => page(x)),
    );
    for (const html of pages) {
      expect(html).toContain("<title>A session on MadeGood</title>");
      expect(html).not.toContain("paddle");
      expect(html).not.toContain("Kayak");
      expect(html).toContain('name="robots" content="noindex"');
    }
    // Every page is identical apart from its own URL.
    const normalized = pages.map((html) => html.replace(/\/s\/[^"]+/g, "/s/ID"));
    expect(new Set(normalized).size).toBe(1);
  });

  it("puts no coordinates in the tags of a public session inside a zone", async () => {
    const owner = await signIn();
    const id = await publicSession(owner, lineTrack);
    await addZone(owner.accessToken, { lat: 0, lon: 0, radiusM: 5000 });
    const html = await page(id);
    expect(html).not.toMatch(/0\.000\d/);
    expect(html).not.toMatch(/og:image|lat|lon/);
  });

  it("keeps the shell's body and passes non-HTML responses through", async () => {
    const shell = new Response(SHELL, { headers: { "content-type": "text/html" } });
    const html = await injectPreview(
      shell,
      { title: "T", description: "D", indexable: false },
      "https://madegood.test/s/x",
    ).text();
    expect(html).toContain("<title>T · MadeGood</title>");
    expect(html).toContain('<div id="root"></div>');
  });
});
