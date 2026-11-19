import {
  createExecutionContext,
  createMessageBatch,
  getQueueResult,
  waitOnExecutionContext,
} from "cloudflare:test";
import { env } from "cloudflare:workers";
import { and, eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/server/app";
import { sessions, users } from "../src/server/db/schema";
import worker from "../src/server/index";
import {
  enqueuePostprocess,
  handlePostprocessBatch,
  processInline,
  processMessage,
  processSession,
  retryDelaySeconds,
  type SessionMessage,
  sweepPendingZoneChanges,
  USER_PAGE,
} from "../src/server/lib/postprocess";
import { SHARED_TRACK_MAX_FIXES } from "../src/server/lib/session-privacy";
import { storeTrack } from "../src/server/lib/session-upload";
import { TrackTooLarge } from "../src/server/lib/track";
import {
  boundsCenter,
  deriveTrack,
  geohash,
  InvalidTrack,
  lonRange,
} from "../src/server/lib/track-derived";
import { fetchWind, WindTransientError, windRequest } from "../src/server/lib/wind";
import { api, bearer, type SignIn, signIn } from "./apple";
import { steadyWest } from "./open-meteo";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.
const START = "2000-01-01T10:00:00.000Z";
const START_MS = Date.parse(START);
/** About 111 m of latitude per 0.001°. */
const DEG_PER_M = 1 / 111_195;

type Fix = [t: number, lat: number, lon: number];

/** A track v1 document with the given fixes, keys sorted as WaterKit writes them. */
const track = (id: string, fixes: Fix[]) => ({
  analyzerVersion: "1.0.0",
  events: [],
  gps: {
    t: fixes.map((f) => f[0]),
    lat: fixes.map((f) => f[1]),
    lon: fixes.map((f) => f[2]),
    spd: fixes.map(() => 2),
    crs: fixes.map(() => 0),
    hacc: fixes.map(() => 4),
  },
  hr: { t: [], bpm: [] },
  sessionId: id,
  sport: "kayak",
  startedAt: START,
  summary: {},
  v: 1,
});

/** A northbound line from 0,0: one fix every 10 s, 10 m apart, for `count` fixes. */
const line = (count: number): Fix[] =>
  Array.from({ length: count }, (_, i) => [i * 10, Number((i * 10 * DEG_PER_M).toFixed(7)), 0]);

async function gzip(text: string) {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const json = (method: string, body: unknown, token: string) => ({
  method,
  headers: { ...bearer(token), "content-type": "application/json" },
  body: JSON.stringify(body),
});

const metadata = { sport: "kayak", startedAt: START, endedAt: "2000-01-01T11:00:00.000Z" };

async function upload(owner: SignIn, id: string, body: unknown, revision = 0) {
  const query = revision > 0 ? `?revision=${revision}` : "";
  const put = await api(`/sessions/${id}${query}`, json("PUT", metadata, owner.accessToken));
  expect([200, 201]).toContain(put.status);
  const response = await api(`/sessions/${id}/track${query}`, {
    method: "PUT",
    headers: { ...bearer(owner.accessToken), "content-type": "application/gzip" },
    body: await gzip(JSON.stringify(body)),
  });
  expect(response.status).toBe(204);
  return response;
}

const row = async (id: string) => {
  const [found] = await drizzle(env.DB).select().from(sessions).where(eq(sessions.id, id));
  if (!found) throw new Error("no row");
  return found;
};

/** The message the upload of `id` queued, rebuilt from the row. */
async function messageFor(id: string): Promise<SessionMessage> {
  const r = await row(id);
  return {
    v: 1,
    sessionId: id,
    userId: r.userId,
    revision: r.uploadRevision,
    etag: r.trackEtag ?? "",
  };
}

async function getSession(token: string | null, id: string) {
  const response = await api(`/sessions/${id}`, { headers: token ? bearer(token) : {} });
  expect(response.status).toBe(200);
  return (await response.json()) as Record<string, unknown>;
}

/** Waits for the real queue consumer (wrangler.jsonc) to finish with the session. */
async function waitUntilProcessed(
  token: string | null,
  id: string,
  check = (s: Record<string, unknown>) => s.processing === "done",
) {
  const deadline = Date.now() + 20_000;
  for (;;) {
    const session = await getSession(token, id);
    if (check(session)) return session;
    if (Date.now() > deadline) throw new Error(`not processed: ${JSON.stringify(session)}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

const noFetch = vi.fn<typeof fetch>(async () => {
  throw new Error("unexpected fetch");
});

describe("derived track data", () => {
  it("finds the smallest longitude range, across the antimeridian too", () => {
    expect(lonRange(Float64Array.from([10, -5, 3]))).toEqual({ west: -5, east: 10 });
    expect(lonRange(Float64Array.from([179.5, -179.5, 179.9]))).toEqual({
      west: 179.5,
      east: -179.5,
    });
    expect(lonRange(new Float64Array())).toBeNull();
    expect(boundsCenter({ south: 0, north: 2, west: 179, east: -179 })).toEqual({
      lat: 1,
      lon: 180,
    });
    expect(boundsCenter({ south: 0, north: 2, west: 178, east: -176 })).toEqual({
      lat: 1,
      lon: -179,
    });
  });

  it("encodes geohashes", () => {
    expect(geohash(57.64911, 10.40744, 11)).toBe("u4pruydqqvj");
    expect(geohash(0.0001, 0.0001, 5)).toBe("s0000");
  });

  it("cuts zones and fixes beyond the map out of the public bounds only", () => {
    const id = crypto.randomUUID();
    const fixes: Fix[] = [...line(100), [995, 86, 0], [996, Number.NaN, 0], [997, 0, 200]];
    // A zone around the first 300 m of the line.
    const zone = { lat: 0, lon: 0, radiusM: 300 };
    const derived = deriveTrack(track(id.toUpperCase(), fixes), id, [zone]);
    expect(derived.bounds).toEqual({ south: 0, north: 86, west: 0, east: 0 });
    expect(derived.publicBounds?.south).toBeGreaterThan(300 * DEG_PER_M);
    expect(derived.publicBounds?.north).toBeCloseTo(990 * DEG_PER_M, 7);
    expect(derived.startGeohash).toBe("s0000");
    expect(derived.startedAt).toBe(START_MS);
    expect(derived.endedAt).toBe(START_MS + 995_000);
    // Everything hidden: no public bounds at all.
    expect(deriveTrack(track(id, line(5)), id, [zone]).publicBounds).toBeNull();
  });

  it("rejects other documents and tracks over the shared fix cap", () => {
    const id = crypto.randomUUID();
    expect(() => deriveTrack(track(crypto.randomUUID(), line(2)), id, [])).toThrow(InvalidTrack);
    expect(() => deriveTrack({ ...track(id, line(2)), v: 2 }, id, [])).toThrow(InvalidTrack);
    const huge = track(id, []);
    huge.gps.t = new Array(SHARED_TRACK_MAX_FIXES + 1).fill(0);
    expect(() => deriveTrack(huge, id, [])).toThrow(TrackTooLarge);
  });
});

describe("Open-Meteo wind", () => {
  const window = { startedAt: START_MS, endedAt: START_MS + 3600_000 };

  it("sends only a rounded position, the UTC dates and the fixed variables", () => {
    const url = windRequest({ lat: 0.12345, lon: -0.06789 }, window, START_MS + 86_400_000);
    expect(url?.origin).toBe("https://api.open-meteo.com");
    expect(Object.fromEntries(url?.searchParams ?? [])).toEqual({
      latitude: "0.1",
      longitude: "-0.1",
      start_date: "2000-01-01",
      end_date: "2000-01-01",
      hourly: "wind_speed_10m,wind_direction_10m,wind_gusts_10m",
      wind_speed_unit: "ms",
      timeformat: "unixtime",
      timezone: "GMT",
    });
    // Older sessions come from the reanalysis archive.
    expect(windRequest({ lat: 0, lon: 0 }, window, START_MS + 365 * 86_400_000)?.origin).toBe(
      "https://archive-api.open-meteo.com",
    );
    expect(windRequest({ lat: 0, lon: 0 }, { startedAt: 2, endedAt: 1 })).toBeNull();
  });

  it("summarizes the hours around the session", async () => {
    const url = windRequest({ lat: 0, lon: 0 }, window, START_MS + 86_400_000) as URL;
    const wind = await fetchWind(
      url,
      window,
      async (input) => steadyWest(new URL(String(input))),
      1,
    );
    expect(wind).toMatchObject({
      status: "ok",
      source: "open-meteo-forecast",
      directionDeg: 270,
      speedMps: 5,
      gustMps: 7,
      fetchedAt: 1,
    });
    // 09:00 to 12:00: the hour before the start through the hour after the end.
    expect(wind.status === "ok" && wind.samples.map((s) => new Date(s.t).getUTCHours())).toEqual([
      9, 10, 11, 12,
    ]);
  });

  it("retries rate limits and outages, but not answers that will not change", async () => {
    const url = windRequest({ lat: 0, lon: 0 }, window) as URL;
    const answer = (response: Response) => async () => response;
    await expect(fetchWind(url, window, answer(new Response("", { status: 429 })))).rejects.toThrow(
      WindTransientError,
    );
    await expect(fetchWind(url, window, answer(new Response("", { status: 502 })))).rejects.toThrow(
      WindTransientError,
    );
    await expect(
      fetchWind(url, window, async () => {
        throw new TypeError("network");
      }),
    ).rejects.toThrow(WindTransientError);
    expect(await fetchWind(url, window, answer(new Response("{}", { status: 400 })))).toMatchObject(
      { status: "unavailable", reason: "http_400" },
    );
    expect(
      await fetchWind(url, window, answer(Response.json({ hourly: { time: "x" } }))),
    ).toMatchObject({ status: "unavailable", reason: "unexpected_response" });
  });
});

describe("upload post-processing", { timeout: 30_000 }, () => {
  it("is queued by a track upload and derives the bounds and times", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    // Cleared by the upload, until the consumer has run.
    const session = await waitUntilProcessed(owner.accessToken, id);
    expect(session).toMatchObject({
      processing: "done",
      bounds: { south: 0, west: 0, east: 0 },
      trackStartedAt: START,
      trackEndedAt: "2000-01-01T10:16:30.000Z",
      wind: null,
    });
    expect((await row(id)).startGeohash).toBe("s0000");
  });

  it("gives others only the bounds of what the shared track shows, and fetches wind", async () => {
    const owner = await signIn();
    const zone = await api(
      "/me/privacy-zones",
      json("POST", { lat: 0, lon: 0, radiusM: 300 }, owner.accessToken),
    );
    expect(zone.status).toBe(201);
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    const patch = await api(
      `/sessions/${id}`,
      json("PATCH", { visibility: "public" }, owner.accessToken),
    );
    expect(patch.status).toBe(200);

    const mine = await waitUntilProcessed(owner.accessToken, id, (s) => s.wind !== null);
    expect((mine.bounds as { south: number }).south).toBe(0);
    const theirs = await getSession(null, id);
    expect((theirs.bounds as { south: number }).south).toBeGreaterThan(300 * DEG_PER_M);
    expect(theirs.wind).toMatchObject({
      source: "open-meteo-archive",
      directionDeg: 270,
      speedMps: 5,
    });
  });

  it("never asks for wind for a private session", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    await waitUntilProcessed(owner.accessToken, id);
    const message = await messageFor(id);
    await drizzle(env.DB).update(sessions).set({ processedEtag: null }).where(eq(sessions.id, id));
    expect(await processSession(env, message, { fetch: noFetch })).toBe("processed");
    expect(noFetch).not.toHaveBeenCalled();
    expect((await row(id)).windJson).toBeNull();
  });

  it("drops duplicates, stale revisions, replaced tracks and deleted sessions", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)), 1);
    const first = await messageFor(id);
    await waitUntilProcessed(owner.accessToken, id);
    expect(await processSession(env, first, { fetch: noFetch })).toBe("skipped_done");

    // A newer revision clears the derived data at once, before its own track arrives.
    const put = await api(`/sessions/${id}?revision=2`, json("PUT", metadata, owner.accessToken));
    expect(put.status).toBe(200);
    expect(await getSession(owner.accessToken, id)).toMatchObject({
      processing: "none",
      bounds: null,
      trackStartedAt: null,
    });
    expect((await row(id)).minLat).toBeNull();
    expect(await processSession(env, first, { fetch: noFetch })).toBe("skipped_stale");

    await upload(owner, id, track(id, line(20)), 2);
    const second = await messageFor(id);
    expect(second.etag).not.toBe(first.etag);
    expect(await processSession(env, { ...second, etag: first.etag }, { fetch: noFetch })).toBe(
      "skipped_stale",
    );

    expect(
      (await api(`/sessions/${id}`, { method: "DELETE", headers: bearer(owner.accessToken) }))
        .status,
    ).toBe(204);
    expect(await processSession(env, second, { fetch: noFetch })).toBe("skipped_stale");
    expect(await processSession(env, { nonsense: true })).toBe("invalid_message");
  });

  it("marks tracks that are not this session's, and keeps their derived data empty", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(crypto.randomUUID(), line(10)));
    const session = await waitUntilProcessed(
      owner.accessToken,
      id,
      (s) => s.processing !== "pending",
    );
    expect(session).toMatchObject({ processing: "invalid", bounds: null });
  });

  it("clears and recomputes public bounds when a privacy zone is added", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await api(`/sessions/${id}`, json("PATCH", { visibility: "unlisted" }, owner.accessToken));
    await waitUntilProcessed(owner.accessToken, id);
    expect(((await getSession(null, id)).bounds as { south: number }).south).toBe(0);

    const zone = await api(
      "/me/privacy-zones",
      json("POST", { lat: 0, lon: 0, radiusM: 300 }, owner.accessToken),
    );
    expect(zone.status).toBe(201);
    // Cleared in the same request, so the old box is never served with the new zone.
    const r = await row(id);
    expect([r.publicMinLat, r.publicZonesVersion]).toEqual([null, null]);
    expect((await getSession(null, id)).bounds).toBeNull();

    expect((await row(id)).windJson).toBeNull();
    const theirs = await waitUntilProcessed(null, id, (s) => s.bounds !== null);
    expect((theirs.bounds as { south: number }).south).toBeGreaterThan(300 * DEG_PER_M);
    // Wind is public data too: cleared with the zone change, then fetched again.
    const refetched = await waitUntilProcessed(null, id, (s) => s.wind !== null);
    expect(refetched.wind).toMatchObject({ directionDeg: 270 });
  });

  it("asks for wind when a processed session is shared later", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    await waitUntilProcessed(owner.accessToken, id);
    expect((await row(id)).windJson).toBeNull();
    await api(`/sessions/${id}`, json("PATCH", { visibility: "public" }, owner.accessToken));
    const shared = await waitUntilProcessed(owner.accessToken, id, (s) => s.wind !== null);
    expect(shared.wind).toMatchObject({ directionDeg: 270 });
  });

  it("acks finished messages and retries failed wind lookups with backoff", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    await waitUntilProcessed(owner.accessToken, id);
    // Shared, but with the wind lookup still to do.
    await drizzle(env.DB)
      .update(sessions)
      .set({ visibility: "public", windJson: null })
      .where(and(eq(sessions.id, id)));
    const message = await messageFor(id);

    // A batch whose acks and retries are recorded, with their retry delays.
    const calls: unknown[] = [];
    const fake = (msgId: string, attempts: number, body: unknown) => ({
      id: msgId,
      timestamp: new Date(),
      attempts,
      body,
      ack: () => calls.push(["ack", msgId]),
      retry: (options?: QueueRetryOptions) => calls.push(["retry", msgId, options?.delaySeconds]),
    });
    const failing = {
      queue: "madegood-postprocess",
      messages: [fake("a", 3, message), fake("b", 1, { bad: 1 })],
    } as unknown as MessageBatch<unknown>;
    const outage = vi.fn<typeof fetch>(async () => new Response("", { status: 503 }));
    await handlePostprocessBatch(failing, env, { fetch: outage });
    expect(calls).toEqual([
      ["retry", "a", 120],
      ["ack", "b"],
    ]);
    expect(outage).toHaveBeenCalledOnce();
    expect((await row(id)).windJson).toBeNull();
    expect([1, 2, 5, 10].map(retryDelaySeconds)).toEqual([30, 60, 480, 3600]);

    // The Worker's own queue handler, with Open-Meteo answering again.
    const retried = createMessageBatch("madegood-postprocess", [
      { id: "c", timestamp: new Date(), attempts: 4, body: message },
    ]);
    const ctx2 = createExecutionContext();
    await worker.queue(retried, env);
    expect((await getQueueResult(retried, ctx2)).explicitAcks).toEqual(["c"]);
    expect(JSON.parse((await row(id)).windJson ?? "null")).toMatchObject({ status: "ok" });
  });

  it("processes after the response when there is no queue binding", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    await waitUntilProcessed(owner.accessToken, id);
    const message = await messageFor(id);
    await drizzle(env.DB).update(sessions).set({ processedEtag: null }).where(eq(sessions.id, id));
    const ctx = createExecutionContext();
    await enqueuePostprocess({ DB: env.DB, TRACKS: env.TRACKS }, ctx, [message]);
    await waitOnExecutionContext(ctx);
    expect((await row(id)).processedEtag).toBe(message.etag);
  });
});

describe("review of #72", { timeout: 30_000 }, () => {
  const addZone = (token: string) =>
    api("/me/privacy-zones", json("POST", { lat: 0, lon: 0, radiusM: 300 }, token));
  const zonesMarker = async (userId: string) => {
    const [marker] = await drizzle(env.DB)
      .select({ version: users.zonesVersion, queued: users.zonesQueuedVersion })
      .from(users)
      .where(eq(users.id, userId));
    if (!marker) throw new Error("no user");
    return marker;
  };
  const south = (s: Record<string, unknown>) => (s.bounds as { south: number } | null)?.south;

  it("never stores a public box cut without a zone added while the track was being read", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await api(`/sessions/${id}`, json("PATCH", { visibility: "public" }, owner.accessToken));
    await waitUntilProcessed(owner.accessToken, id);
    const message = await messageFor(id);
    // Force a recompute, and add a zone between deriving (without it) and writing.
    await drizzle(env.DB).update(sessions).set({ processedEtag: null }).where(eq(sessions.id, id));
    let added = false;
    const outcome = await processSession(env, message, {
      // Shared, and the zone change clears its wind, so it asks again.
      fetch: async (input) => steadyWest(new URL(String(input))),
      hooks: {
        afterDerive: async () => {
          if (added) return;
          added = true;
          expect((await addZone(owner.accessToken)).status).toBe(201);
        },
      },
    });
    expect(outcome).toBe("processed");
    const r = await row(id);
    const [{ version } = { version: -1 }] = await drizzle(env.DB)
      .select({ version: users.zonesVersion })
      .from(users)
      .where(eq(users.id, owner.user.id));
    // The stale write was refused; the second pass used the zone.
    expect(r.publicZonesVersion).toBe(version);
    expect(r.publicMinLat).toBeGreaterThan(300 * DEG_PER_M);
    expect(south(await getSession(null, id))).toBeGreaterThan(300 * DEG_PER_M);
  });

  it("serves no public data computed at an older zones version, and recomputes it", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await api(`/sessions/${id}`, json("PATCH", { visibility: "public" }, owner.accessToken));
    await waitUntilProcessed(owner.accessToken, id);
    const before = await row(id);
    // A zone change the row has not caught up with (as if its requeue were still pending).
    await drizzle(env.DB)
      .update(users)
      .set({ zonesVersion: (before.publicZonesVersion ?? 0) + 1 })
      .where(eq(users.id, owner.user.id));
    const theirs = await getSession(null, id);
    expect([theirs.bounds, theirs.trackStartedAt]).toEqual([null, null]);
    expect(south(await getSession(owner.accessToken, id))).toBe(0);
    // processedEtag still matches, yet the message recomputes instead of skipping.
    expect(await processSession(env, await messageFor(id), { fetch: noFetch })).toBe("processed");
    expect(south(await getSession(null, id))).toBe(0);
  });

  it("gives others only the times of fixes outside the zones", async () => {
    const owner = await signIn();
    expect((await addZone(owner.accessToken)).status).toBe(201);
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await api(`/sessions/${id}`, json("PATCH", { visibility: "unlisted" }, owner.accessToken));
    const mine = await waitUntilProcessed(owner.accessToken, id);
    expect(mine.trackStartedAt).toBe(START);
    const theirs = await getSession(null, id);
    // 10 m a fix: the first fix outside 300 m is the 31st, 300 s in.
    expect(Date.parse(theirs.trackStartedAt as string)).toBeGreaterThanOrEqual(START_MS + 300_000);
    expect(theirs.trackEndedAt).toBe(mine.trackEndedAt);
  });

  it("ends a same-revision upload race at the stored object's ETag", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    const db = drizzle(env.DB);
    const key = (await row(id)).trackKey as string;
    const bytes = async (n: number) => gzip(JSON.stringify(track(id, line(n))));
    const input = { id, userId: owner.user.id, revision: 0, key };
    const [a, b] = [await bytes(20), await bytes(30)];
    // A puts, then B puts and attaches, then A attaches its own (now overwritten) ETag.
    let second: Awaited<ReturnType<typeof storeTrack>> | undefined;
    const first = await storeTrack(
      db,
      env.TRACKS,
      { ...input, bytes: a },
      {
        afterPut: async () => {
          second = await storeTrack(db, env.TRACKS, { ...input, bytes: b });
        },
      },
    );
    const head = await env.TRACKS.head(key);
    expect(second).toMatchObject({ kind: "attached", etag: head?.etag, replaced: false });
    // A lost: it reports B's ETag and that its own bytes were replaced (the route's 412).
    expect(first).toMatchObject({ kind: "attached", etag: head?.etag, replaced: true });
    expect((await row(id)).trackEtag).toBe(head?.etag);
    // So the message both uploads send gets processed rather than dropped.
    const message = await messageFor(id);
    expect(await processSession(env, message, { fetch: noFetch })).toBe("processed");
    expect((await row(id)).trackEndedAt).toBe(START_MS + 290_000);
  });

  it("does not ask for wind once the session is made private", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    await waitUntilProcessed(owner.accessToken, id);
    const message = await messageFor(id);
    const share = (visibility: "public" | "private") =>
      drizzle(env.DB)
        .update(sessions)
        .set({ visibility, windJson: null })
        .where(eq(sessions.id, id));

    // Private between the snapshot and the request: no request at all.
    await share("public");
    expect(
      await processSession(env, message, {
        fetch: noFetch,
        hooks: { beforeWind: () => share("private").then(() => undefined) },
      }),
    ).toBe("skipped_done");
    expect(noFetch).not.toHaveBeenCalled();

    // Private while the request is in flight: the answer is not stored.
    await share("public");
    const slow = vi.fn<typeof fetch>(async (input) => {
      await share("private");
      return steadyWest(new URL(String(input)));
    });
    await processSession(env, message, { fetch: slow });
    expect(slow).toHaveBeenCalledOnce();
    expect((await row(id)).windJson).toBeNull();
  });

  it("fans a zone change out through one user message, page by page", async () => {
    const owner = await signIn();
    const db = drizzle(env.DB);
    const ids = Array.from({ length: USER_PAGE + 1 }, () => crypto.randomUUID()).sort();
    const rows = ids.map((id) => ({
      id,
      userId: owner.user.id,
      sport: "kayak" as const,
      startedAt: START_MS,
      trackKey: `users/${owner.user.id}/sessions/${id}/track.v1.gz`,
      trackEtag: "e",
    }));
    for (let i = 0; i < rows.length; i += 5) await db.insert(sessions).values(rows.slice(i, i + 5));
    const sent: unknown[] = [];
    const queue = {
      send: async (body: unknown) => void sent.push(body),
      sendBatch: async (batch: { body: unknown }[]) => void sent.push(...batch.map((m) => m.body)),
    } as unknown as Queue<never>;
    const queued = { DB: env.DB, TRACKS: env.TRACKS, POSTPROCESS: queue };
    const user = { v: 1, kind: "user", userId: owner.user.id };
    expect(await processMessage(queued, user)).toBe("user_requeued");
    expect(sent).toHaveLength(USER_PAGE + 1);
    expect(sent.at(-1)).toEqual({ ...user, after: ids[USER_PAGE - 1] });
    sent.length = 0;
    await processMessage(queued, { ...user, after: ids[USER_PAGE - 1] });
    expect(sent).toEqual([expect.objectContaining({ sessionId: ids[USER_PAGE] })]);
    // A failed send retries the user message instead of losing the rest.
    const failing = {
      ...queued,
      POSTPROCESS: {
        sendBatch: async () => Promise.reject(new Error("down")),
      } as unknown as Queue<never>,
    };
    await expect(processMessage(failing, user)).rejects.toThrow("down");
  });

  it("refuses a zone change it cannot queue, and leaves no zone behind", async () => {
    const owner = await signIn();
    const app = createApp();
    const failing = {
      send: async () => Promise.reject(new Error("down")),
      sendBatch: async () => Promise.reject(new Error("down")),
    };
    // A plain object: assigning onto `env` itself would change the binding for other tests.
    const bindings = {
      DB: env.DB,
      TRACKS: env.TRACKS,
      JWT_SIGNING_KEY: env.JWT_SIGNING_KEY,
      APPLE_AUDIENCES: env.APPLE_AUDIENCES,
      POSTPROCESS: failing,
    };
    const response = await app.request(
      "/api/me/privacy-zones",
      json("POST", { lat: 0, lon: 0, radiusM: 300 }, owner.accessToken),
      bindings,
      createExecutionContext(),
    );
    expect(response.status).toBe(503);
    const list = await api("/me/privacy-zones", { headers: bearer(owner.accessToken) });
    expect(await list.json()).toEqual({ zones: [] });
    // The rollback is itself a zone change; its reprocessing is left marked, not lost.
    const marker = await zonesMarker(owner.user.id);
    expect(marker.queued).toBeLessThan(marker.version);
    expect(await sweepPendingZoneChanges(env, createExecutionContext())).toBeGreaterThanOrEqual(1);
    const after = await zonesMarker(owner.user.id);
    expect(after.queued).toBe(after.version);
  });

  it("reprocesses a zone change inline, bounded, without a queue", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await waitUntilProcessed(owner.accessToken, id);
    await drizzle(env.DB)
      .update(sessions)
      .set({ publicZonesVersion: null, visibility: "public", windJson: "{}" })
      .where(eq(sessions.id, id));
    await processInline({ DB: env.DB, TRACKS: env.TRACKS }, [
      { v: 1, kind: "user", userId: owner.user.id },
    ]);
    expect((await row(id)).publicZonesVersion).not.toBeNull();
  });
});

describe("scoped re-check of #72", { timeout: 30_000 }, () => {
  const south = (s: Record<string, unknown>) => (s.bounds as { south: number } | null)?.south;
  const addZone = (token: string) =>
    api("/me/privacy-zones", json("POST", { lat: 0, lon: 0, radiusM: 300 }, token));
  const failingQueue = {
    send: async () => Promise.reject(new Error("down")),
    sendBatch: async () => Promise.reject(new Error("down")),
  };
  /** The app with a queue that rejects every send. */
  const withFailingQueue = (path: string, init: RequestInit) =>
    createApp().request(
      `/api${path}`,
      init,
      {
        DB: env.DB,
        TRACKS: env.TRACKS,
        JWT_SIGNING_KEY: env.JWT_SIGNING_KEY,
        APPLE_AUDIENCES: env.APPLE_AUDIENCES,
        POSTPROCESS: failingQueue,
      },
      createExecutionContext(),
    );
  const marker = async (userId: string) => {
    const [m] = await drizzle(env.DB)
      .select({ version: users.zonesVersion, queued: users.zonesQueuedVersion })
      .from(users)
      .where(eq(users.id, userId));
    if (!m) throw new Error("no user");
    return m;
  };

  it("never serves wind from before a zone change, nor stores one fetched across it", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await api(`/sessions/${id}`, json("PATCH", { visibility: "public" }, owner.accessToken));
    await waitUntilProcessed(null, id, (s) => s.wind !== null);

    // Stale public data (a zone change not yet applied to the row): no wind for others.
    const r = await row(id);
    await drizzle(env.DB)
      .update(users)
      .set({ zonesVersion: (r.publicZonesVersion ?? 0) + 1 })
      .where(eq(users.id, owner.user.id));
    expect((await getSession(null, id)).wind).toBeNull();
    expect((await getSession(owner.accessToken, id)).wind).not.toBeNull();

    // A zone added while Open-Meteo answers: the answer is not stored.
    await drizzle(env.DB)
      .update(sessions)
      .set({ publicZonesVersion: null, windJson: null })
      .where(eq(sessions.id, id));
    await drizzle(env.DB)
      .update(users)
      .set({
        zonesVersion: r.publicZonesVersion ?? 0,
        zonesQueuedVersion: r.publicZonesVersion ?? 0,
      })
      .where(eq(users.id, owner.user.id));
    let added = false;
    const racing = vi.fn<typeof fetch>(async (input) => {
      if (!added) {
        added = true;
        expect((await addZone(owner.accessToken)).status).toBe(201);
      }
      return steadyWest(new URL(String(input)));
    });
    await processSession(env, await messageFor(id), { fetch: racing });
    expect(racing).toHaveBeenCalled();
    const after = await row(id);
    expect(
      after.windJson === null || after.publicZonesVersion === (await marker(owner.user.id)).version,
    ).toBe(true);
    if (after.windJson !== null) expect(after.publicMinLat).toBeGreaterThan(300 * DEG_PER_M);
  });

  it("asks for wind on the dates others can see, not the hidden start's", async () => {
    const owner = await signIn();
    expect((await addZone(owner.accessToken)).status).toBe(201);
    const id = crypto.randomUUID();
    // Starts at 23:57 UTC; the zone hides the first 300 s, past midnight.
    const doc = { ...track(id, line(100)), startedAt: "2000-01-01T23:57:00.000Z" };
    await upload(owner, id, doc);
    await waitUntilProcessed(owner.accessToken, id);
    await drizzle(env.DB)
      .update(sessions)
      .set({ visibility: "public", windJson: null })
      .where(eq(sessions.id, id));
    const urls: URL[] = [];
    const capture = vi.fn<typeof fetch>(async (input) => {
      const url = new URL(String(input));
      urls.push(url);
      return steadyWest(url);
    });
    await processSession(env, await messageFor(id), { fetch: capture });
    expect(urls.map((u) => u.searchParams.get("start_date"))).toEqual(["2000-01-02"]);
  });

  it("does nothing when deleting an unknown zone", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    await waitUntilProcessed(owner.accessToken, id);
    const before = await marker(owner.user.id);
    const response = await withFailingQueue(`/me/privacy-zones/${crypto.randomUUID()}`, {
      method: "DELETE",
      headers: bearer(owner.accessToken),
    });
    expect(response.status).toBe(204);
    expect(await marker(owner.user.id)).toEqual(before);
    expect((await row(id)).publicZonesVersion).toBe(before.version);
  });

  it("keeps a failed delete's reprocessing until an upload or the sweep queues it", async () => {
    const owner = await signIn();
    const zone = (await (await addZone(owner.accessToken)).json()) as { id: string };
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(100)));
    await waitUntilProcessed(owner.accessToken, id);

    const response = await withFailingQueue(`/me/privacy-zones/${zone.id}`, {
      method: "DELETE",
      headers: bearer(owner.accessToken),
    });
    expect(response.status).toBe(503);
    const pending = await marker(owner.user.id);
    expect(pending.queued).toBeLessThan(pending.version);
    expect((await row(id)).publicZonesVersion).toBeNull();

    // The next upload, with a working queue, queues it and the data comes back.
    const other = crypto.randomUUID();
    await upload(owner, other, track(other, line(10)));
    const caught = await marker(owner.user.id);
    expect(caught.queued).toBe(caught.version);
    const theirs = await waitUntilProcessed(owner.accessToken, id, () => true);
    await api(`/sessions/${id}`, json("PATCH", { visibility: "public" }, owner.accessToken));
    expect(theirs.processing).toBe("done");
    const shared = await waitUntilProcessed(null, id, (s) => s.bounds !== null);
    expect(south(shared)).toBe(0);
  });

  it("reports the stored ETag to an upload that loses after attaching", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await upload(owner, id, track(id, line(10)));
    const db = drizzle(env.DB);
    const key = (await row(id)).trackKey as string;
    const input = { id, userId: owner.user.id, revision: 0, key };
    const a = await gzip(JSON.stringify(track(id, line(20))));
    const b = await gzip(JSON.stringify(track(id, line(30))));
    // A puts and attaches; B puts and attaches before A reads the object back.
    const first = await storeTrack(
      db,
      env.TRACKS,
      { ...input, bytes: a },
      {
        afterAttach: async () => {
          await storeTrack(db, env.TRACKS, { ...input, bytes: b });
        },
      },
    );
    const head = await env.TRACKS.head(key);
    expect(first).toMatchObject({ kind: "attached", etag: head?.etag, replaced: true });
    expect((await row(id)).trackEtag).toBe(head?.etag);
  });

  it("keeps migration 0007 as previews applied it, with the later columns in 0008", () => {
    const byName = Object.fromEntries(
      env.TEST_MIGRATIONS.map((m) => [m.name, m.queries.join("\n")]),
    );
    const first = byName["0007_session_postprocessing.sql"] ?? "";
    const second = byName["0008_public_zones_version.sql"] ?? "";
    expect(first.match(/ALTER TABLE/g)).toHaveLength(9);
    expect(first).not.toMatch(/public_zones_version|public_track_started_at|zones_version/);
    expect(second).toMatch(/public_zones_version/);
    expect(second).toMatch(/zones_queued_version/);
  });
});
