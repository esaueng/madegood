import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { describe, expect, it } from "vitest";
import { collectR2Garbage } from "../src/server/lib/r2-garbage";
import { replaceSessionMetadata } from "../src/server/lib/session-upload";
import { api, bearer, deleteMe, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.
const START = "2000-01-01T10:00:00.000Z";
const TRACK_LIMIT = 8 * 1024 * 1024;

const metadata = (overrides: Record<string, unknown> = {}) => ({
  sport: "kayak",
  startedAt: START,
  endedAt: "2000-01-01T11:00:00.000Z",
  durationS: 3600,
  movingS: 3300,
  distanceM: 5000,
  maxSpeedMps: 2.4,
  avgSpeedMps: 1.52,
  summary: { distance: 5000, movingTime: 3300, elapsed: 3600, laps: [] },
  analyzerVersion: "1.0.0",
  ...overrides,
});

const putSession = (token: string | null, id: string, body: unknown = metadata()) =>
  api(`/sessions/${id}`, {
    method: "PUT",
    headers: { ...(token ? bearer(token) : {}), "content-type": "application/json" },
    body: JSON.stringify(body),
  });

const patchSession = (token: string, id: string, body: unknown) =>
  api(`/sessions/${id}`, {
    method: "PATCH",
    headers: { ...bearer(token), "content-type": "application/json" },
    body: JSON.stringify(body),
  });

const getSession = (token: string | null, id: string) =>
  api(`/sessions/${id}`, { headers: token ? bearer(token) : {} });

const getTrack = (token: string | null, id: string) =>
  api(`/sessions/${id}/track`, { headers: token ? bearer(token) : {} });

const deleteSession = (token: string, id: string) =>
  api(`/sessions/${id}`, { method: "DELETE", headers: bearer(token) });

async function gzip(text: string): Promise<Uint8Array> {
  const stream = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function gunzip(bytes: ArrayBuffer): Promise<string> {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).text();
}

/** A small track v1 file, keys sorted as WaterKit writes them. */
const trackJson = (id: string) =>
  JSON.stringify({
    analyzerVersion: "1.0.0",
    events: [],
    gps: {
      t: [0, 1],
      lat: [0.0001, 0.00011],
      lon: [0.0002, 0.0002],
      spd: [1.5, 1.6],
      crs: [10, 10],
      hacc: [4, 4],
    },
    hr: { t: [], bpm: [] },
    sessionId: id,
    sport: "kayak",
    startedAt: START,
    summary: {},
    v: 1,
  });

const putTrack = (
  token: string,
  id: string,
  body: BodyInit,
  headers: Record<string, string> = { "content-type": "application/gzip" },
) =>
  api(`/sessions/${id}/track`, { method: "PUT", headers: { ...bearer(token), ...headers }, body });

/** Every R2 object under a session's prefix (each upload attempt has its own key). */
async function sessionObjects(userId: string, id: string): Promise<string[]> {
  const listed = await env.TRACKS.list({ prefix: `users/${userId}/sessions/${id}/` });
  return listed.objects.map((o) => o.key);
}

/** The key the session row names, or null. */
async function rowKey(id: string): Promise<string | null> {
  const row = await env.DB.prepare("select track_key as k from sessions where id = ?")
    .bind(id)
    .first<{ k: string | null }>();
  return row?.k ?? null;
}

/** A per-attempt upload key (lib/track.ts). */
const UPLOAD_KEY = /\/track\.v1\.r\d+\.[0-9a-f-]{36}\.gz$/;

/**
 * Starts a track upload whose body stops after its first bytes. `reading` resolves once
 * the handler asks for more, which it does only after checking the session, so a test can
 * act while the upload is known to be mid-body; `finish` sends the rest.
 */
function pausedUpload(token: string, id: string, bytes: Uint8Array) {
  let reading: () => void = () => {};
  const readingStarted = new Promise<void>((resolve) => {
    reading = resolve;
  });
  let release: () => void = () => {};
  const released = new Promise<void>((resolve) => {
    release = resolve;
  });
  let sent = false;
  const body = new ReadableStream<Uint8Array>(
    {
      async pull(controller) {
        if (!sent) {
          sent = true;
          controller.enqueue(bytes.slice(0, 10));
          return;
        }
        reading();
        await released;
        controller.enqueue(bytes.slice(10));
        controller.close();
      },
    },
    { highWaterMark: 0 },
  );
  return { reading: readingStarted, finish: release, response: putTrack(token, id, body) };
}

async function sessionWithTrack(owner: SignIn, visibility?: string) {
  const id = crypto.randomUUID();
  expect((await putSession(owner.accessToken, id)).status).toBe(201);
  expect((await putTrack(owner.accessToken, id, await gzip(trackJson(id)))).status).toBe(204);
  if (visibility) {
    expect((await patchSession(owner.accessToken, id, { visibility })).status).toBe(200);
  }
  return id;
}

describe("PUT /api/sessions/:id", () => {
  it("creates a session with the user's default visibility, then replaces it idempotently", async () => {
    const owner = await signIn();
    await api("/me", {
      method: "PATCH",
      headers: { ...bearer(owner.accessToken), "content-type": "application/json" },
      body: JSON.stringify({ defaultVisibility: "unlisted" }),
    });
    const id = crypto.randomUUID();

    const created = await putSession(owner.accessToken, id);
    expect(created.status).toBe(201);
    const body = (await created.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      id,
      sport: "kayak",
      visibility: "unlisted",
      title: null,
      startedAt: START,
      endedAt: "2000-01-01T11:00:00.000Z",
      distanceM: 5000,
      summary: { distance: 5000, laps: [] },
      analyzerVersion: "1.0.0",
      hasTrack: false,
      isOwner: true,
    });

    // A retry with the same body changes nothing but the timestamp.
    const retried = await putSession(owner.accessToken, id);
    expect(retried.status).toBe(200);
    expect(await retried.json()).toMatchObject({ ...body, updatedAt: expect.any(String) });

    // A re-analysis replaces the device fields; omitted ones become null. Title and
    // visibility set by the user stay.
    await patchSession(owner.accessToken, id, { title: "Morning paddle", visibility: "public" });
    const reanalyzed = await putSession(owner.accessToken, id, {
      sport: "kayak",
      startedAt: START,
      distanceM: 5100,
      analyzerVersion: "1.1.0",
    });
    expect(reanalyzed.status).toBe(200);
    expect(await reanalyzed.json()).toMatchObject({
      distanceM: 5100,
      durationS: null,
      summary: null,
      analyzerVersion: "1.1.0",
      title: "Morning paddle",
      visibility: "public",
    });

    const rows = await env.DB.prepare("select count(*) as n from sessions where id = ?")
      .bind(id)
      .first<{ n: number }>();
    expect(rows?.n).toBe(1);
  });

  it("stores an uppercase device UUID lowercase, as the same session", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSession(owner.accessToken, id.toUpperCase())).status).toBe(201);
    expect((await putSession(owner.accessToken, id)).status).toBe(200);
    const response = await getSession(owner.accessToken, id.toUpperCase());
    expect(await response.json()).toMatchObject({ id });
  });

  it("never overwrites another user's session", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = crypto.randomUUID();
    await putSession(owner.accessToken, id);

    const response = await putSession(other.accessToken, id, metadata({ distanceM: 1 }));
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: "session_id_taken" });

    const mine = (await (await getSession(owner.accessToken, id)).json()) as { distanceM: number };
    expect(mine.distanceM).toBe(5000);
  });

  it("validates the ID, units and ranges", async () => {
    const owner = await signIn();
    expect((await putSession(owner.accessToken, "not-a-uuid")).status).toBe(400);
    const id = crypto.randomUUID();
    for (const body of [
      {},
      metadata({ sport: "rowing" }),
      metadata({ startedAt: "yesterday" }),
      metadata({ startedAt: "1990-01-01T00:00:00Z" }),
      metadata({ startedAt: new Date(Date.now() + 3 * 86400_000).toISOString() }),
      metadata({ endedAt: "2000-01-01T09:00:00Z" }),
      metadata({ endedAt: "2000-01-09T10:00:00Z" }),
      metadata({ durationS: -1 }),
      metadata({ movingS: 4000 }),
      metadata({ distanceM: -5 }),
      metadata({ maxSpeedMps: 51 }),
      metadata({ avgSpeedMps: "fast" }),
      metadata({ summary: [1, 2] }),
      metadata({ summary: { blob: "x".repeat(70_000) } }),
      metadata({ analyzerVersion: "latest" }),
      metadata({ visibility: "public" }),
      metadata({ userId: "someone-else" }),
    ]) {
      const response = await putSession(owner.accessToken, id, body);
      expect(response.status, JSON.stringify(body).slice(0, 80)).toBe(400);
      expect(await response.json()).toMatchObject({ error: "invalid_request" });
    }
  });

  it("requires a token", async () => {
    const response = await putSession(null, crypto.randomUUID());
    expect(response.status).toBe(401);
  });
});

describe("PUT /api/sessions/:id/track", () => {
  it("stores the track under the user's prefix, idempotently", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await putSession(owner.accessToken, id);
    const file = await gzip(trackJson(id));

    for (let i = 0; i < 2; i++) {
      const response = await putTrack(owner.accessToken, id, file);
      expect(response.status).toBe(204);
      expect(response.headers.get("etag")).toBeTruthy();
    }
    // Each upload has its own object; the one it replaced is deleted, so one remains, and it
    // is the one the row names.
    const key = await rowKey(id);
    expect(key).toMatch(UPLOAD_KEY);
    expect(key?.startsWith(`users/${owner.user.id}/sessions/${id}/`)).toBe(true);
    const object = await env.TRACKS.get(key as string);
    expect(object?.httpMetadata?.contentType).toBe("application/gzip");
    expect(new Uint8Array(await (object as R2ObjectBody).arrayBuffer())).toEqual(file);
    const listed = await env.TRACKS.list({ prefix: `users/${owner.user.id}/` });
    expect(listed.objects.map((o) => o.key)).toEqual([key]);
    const pending = await env.DB.prepare(
      "select count(*) as n from pending_r2_deletes where user_id = ?",
    )
      .bind(owner.user.id)
      .first<{ n: number }>();
    expect(pending?.n).toBe(0);

    const session = await (await getSession(owner.accessToken, id)).json();
    expect(session).toMatchObject({ hasTrack: true });
  });

  it("requires the session's metadata first, from the same user", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = crypto.randomUUID();
    const file = await gzip(trackJson(id));

    const missing = await putTrack(owner.accessToken, id, file);
    expect(missing.status).toBe(404);
    expect(await missing.json()).toMatchObject({ error: "not_found" });

    await putSession(owner.accessToken, id);
    expect((await putTrack(other.accessToken, id, file)).status).toBe(404);
    expect(await sessionObjects(other.user.id, id)).toEqual([]);
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
  });

  it("refuses a track over 8 MiB", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await putSession(owner.accessToken, id);
    const file = new Uint8Array(TRACK_LIMIT + 1);
    file.set([0x1f, 0x8b, 8]);

    const response = await putTrack(owner.accessToken, id, file);
    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ error: "payload_too_large" });
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);

    // A body without a Content-Length is counted while it is read.
    const streamed = await putTrack(owner.accessToken, id, new Blob([file]).stream());
    expect(streamed.status).toBe(413);
  });

  it("refuses bodies that are not a gzipped JSON track", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await putSession(owner.accessToken, id);
    const file = await gzip(trackJson(id));

    const plain = await putTrack(owner.accessToken, id, trackJson(id));
    expect(plain.status).toBe(400);
    expect(await plain.json()).toMatchObject({ error: "invalid_track" });

    const notJson = await putTrack(owner.accessToken, id, await gzip("hello"));
    expect(notJson.status).toBe(400);

    const corrupt = file.slice();
    corrupt.fill(0xff, 10, 30);
    expect((await putTrack(owner.accessToken, id, corrupt)).status).toBe(400);

    // A trailer that declares more than 64 MiB inflated.
    const bomb = file.slice();
    new DataView(bomb.buffer).setUint32(bomb.byteLength - 4, 65 * 1024 * 1024, true);
    expect((await putTrack(owner.accessToken, id, bomb)).status).toBe(400);

    for (const headers of <Record<string, string>[]>[
      { "content-type": "application/json" },
      { "content-type": "application/json", "content-encoding": "gzip" },
      { "content-type": "application/gzip", "content-encoding": "gzip" },
    ]) {
      const response = await putTrack(owner.accessToken, id, file, headers);
      expect(response.status, JSON.stringify(headers)).toBe(415);
      expect(await response.json()).toMatchObject({ error: "unsupported_media_type" });
    }
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
  });
});

describe("visibility", () => {
  it("lets the owner see a private session, and nobody else know it exists", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = await sessionWithTrack(owner);

    const own = await getSession(owner.accessToken, id);
    expect(own.status).toBe(200);
    expect(await own.json()).toMatchObject({ visibility: "private", isOwner: true });
    expect((await getTrack(owner.accessToken, id)).status).toBe(200);

    for (const token of [other.accessToken, null]) {
      for (const response of [await getSession(token, id), await getTrack(token, id)]) {
        expect(response.status).toBe(404);
        expect(await response.json()).toMatchObject({ error: "not_found" });
      }
    }
    // The same answer as for a session that does not exist.
    expect((await getSession(other.accessToken, crypto.randomUUID())).status).toBe(404);
  });

  it("shows public and unlisted sessions and tracks to everyone", async () => {
    const owner = await signIn();
    const other = await signIn();
    for (const visibility of ["public", "unlisted"]) {
      const id = await sessionWithTrack(owner, visibility);
      for (const token of [other.accessToken, null]) {
        const session = await getSession(token, id);
        expect(session.status).toBe(200);
        expect(await session.json()).toMatchObject({ id, visibility, isOwner: false });

        const track = await getTrack(token, id);
        expect(track.status).toBe(200);
        expect(track.headers.get("content-type")).toBe("application/gzip");
        expect(track.headers.get("cache-control")).toContain("private");
        expect(JSON.parse(await gunzip(await track.arrayBuffer()))).toMatchObject({ v: 1 });
      }
    }
  });

  // Review of #63: shared session pages must not chart the owner's heart rate.
  it("gives others the track without heart rate, marks or free-form event data", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = crypto.randomUUID();
    expect((await putSession(owner.accessToken, id)).status).toBe(201);
    const withHr = {
      ...JSON.parse(trackJson(id)),
      hr: { t: [0, 1], bpm: [120, 125] },
      events: [
        { t: 0.5, type: "mark", data: { lat: 0.0001, lon: 0.0002 } },
        { t: 1, type: "tack", data: { durationS: 6, note: "x" } },
      ],
    };
    expect((await putTrack(owner.accessToken, id, await gzip(JSON.stringify(withHr)))).status).toBe(
      204,
    );
    expect((await patchSession(owner.accessToken, id, { visibility: "public" })).status).toBe(200);

    for (const token of [other.accessToken, null]) {
      const shared = JSON.parse(await gunzip(await (await getTrack(token, id)).arrayBuffer()));
      expect(shared.hr).toEqual({ t: [], bpm: [] });
      expect(shared.events).toEqual([{ t: 1, type: "tack", data: { durationS: 6 } }]);
      expect(shared.gps.lat).toEqual([0.0001, 0.00011]);
    }
    const mine = JSON.parse(
      await gunzip(await (await getTrack(owner.accessToken, id)).arrayBuffer()),
    );
    expect(mine.hr.bpm).toEqual([120, 125]);
  });

  // Regression test from review of #37: a coordinate in the summary must not reach anyone
  // but the owner.
  it("shows others only the shared summary numbers, never positions or heart rate", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = crypto.randomUUID();
    const summary = {
      distance: 5000,
      movingTime: 3300,
      elapsed: 3600,
      maxSpeed10s: 2.4,
      best500m: 2.2,
      heartRateMax: 150,
      start: { lat: 0.0001, lon: 0.0002 },
      laps: [
        { start: 0, end: 600, distance: 1000, movingTime: 590, auto: true, at: [0.0001, 0.0002] },
      ],
    };
    expect((await putSession(owner.accessToken, id, metadata({ summary }))).status).toBe(201);
    expect((await patchSession(owner.accessToken, id, { visibility: "public" })).status).toBe(200);

    const mine = (await (await getSession(owner.accessToken, id)).json()) as { summary: unknown };
    expect(mine.summary).toEqual(summary);
    for (const token of [other.accessToken, null]) {
      const theirs = (await (await getSession(token, id)).json()) as { summary: unknown };
      expect(theirs.summary).toEqual({
        distance: 5000,
        movingTime: 3300,
        elapsed: 3600,
        maxSpeed10s: 2.4,
        best500m: 2.2,
        laps: [{ start: 0, end: 600, distance: 1000, movingTime: 590, auto: true }],
      });
    }
  });

  it("gives others a privacy-trimmed copy of the track, and the owner the file as uploaded", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = await sessionWithTrack(owner, "public");
    // The test track's fixes are about 25 m from 0,0.
    await env.DB.prepare(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0, 0, 200)",
    )
      .bind(crypto.randomUUID(), owner.user.id)
      .run();

    for (const token of [other.accessToken, null]) {
      expect((await getSession(token, id)).status).toBe(200);
      const track = await getTrack(token, id);
      expect(track.status).toBe(200);
      const shared = JSON.parse(await gunzip(await track.arrayBuffer()));
      expect(shared.gps.t).toEqual([]);
      expect(shared.gps.lat).toEqual([]);
    }
    const mine = await getTrack(owner.accessToken, id);
    expect(JSON.parse(await gunzip(await mine.arrayBuffer()))).toEqual(JSON.parse(trackJson(id)));
  });

  it("returns 404 for a session without a track", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await putSession(owner.accessToken, id);
    expect((await getTrack(owner.accessToken, id)).status).toBe(404);
  });

  it("rejects an invalid token instead of treating it as anonymous", async () => {
    const owner = await signIn();
    const id = await sessionWithTrack(owner, "public");
    expect((await getSession("not-a-token", id)).status).toBe(401);
    expect((await getTrack("not-a-token", id)).status).toBe(401);
  });
});

describe("GET /api/sessions", () => {
  it("pages through the owner's sessions newest first, stable on ties", async () => {
    const owner = await signIn();
    const other = await signIn();
    await putSession(other.accessToken, crypto.randomUUID());

    // Seven sessions; three share a start time, so the ID must break the tie.
    const starts = [0, 1, 1, 1, 2, 3, 4].map((h) => `2000-01-0${h + 1}T10:00:00.000Z`);
    const ids: string[] = [];
    for (const startedAt of starts) {
      const id = crypto.randomUUID();
      ids.push(id);
      await putSession(owner.accessToken, id, metadata({ startedAt, endedAt: null }));
    }
    const expected = ids
      .map((id, i) => ({ id, startedAt: starts[i] as string }))
      .sort((a, b) => b.startedAt.localeCompare(a.startedAt) || b.id.localeCompare(a.id))
      .map((s) => s.id);

    const seen: string[] = [];
    let cursor: string | null = null;
    let pages = 0;
    do {
      const query: string = cursor ? `?limit=3&cursor=${cursor}` : "?limit=3";
      const response = await api(`/sessions${query}`, { headers: bearer(owner.accessToken) });
      expect(response.status).toBe(200);
      const page = (await response.json()) as {
        sessions: { id: string }[];
        nextCursor: string | null;
      };
      seen.push(...page.sessions.map((s) => s.id));
      cursor = page.nextCursor;
      pages++;
    } while (cursor && pages < 10);

    expect(pages).toBe(3);
    expect(seen).toEqual(expected);
  });

  it("returns an empty last page without a cursor, and validates the cursor", async () => {
    const owner = await signIn();
    const empty = await api("/sessions", { headers: bearer(owner.accessToken) });
    expect(await empty.json()).toEqual({ sessions: [], nextCursor: null });

    for (const query of ["?cursor=garbage", "?cursor=WzEsMl0", "?limit=0", "?limit=101"]) {
      const response = await api(`/sessions${query}`, { headers: bearer(owner.accessToken) });
      expect(response.status, query).toBe(400);
      expect(await response.json()).toMatchObject({ error: "invalid_request" });
    }
    expect((await api("/sessions")).status).toBe(401);
  });
});

describe("PATCH /api/sessions/:id", () => {
  it("changes title, notes and visibility for the owner only", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = crypto.randomUUID();
    await putSession(owner.accessToken, id);

    const response = await patchSession(owner.accessToken, id, {
      title: "  Harbour loop ",
      notes: "Light wind.",
      visibility: "public",
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      title: "Harbour loop",
      notes: "Light wind.",
      visibility: "public",
    });

    const cleared = await patchSession(owner.accessToken, id, { title: " ", notes: null });
    expect(await cleared.json()).toMatchObject({ title: null, notes: null, visibility: "public" });

    // Even a public session is not the other user's to change.
    const theirs = await patchSession(other.accessToken, id, { title: "Mine now" });
    expect(theirs.status).toBe(404);

    for (const body of [{ visibility: "friends" }, { title: "x".repeat(101) }, { sport: "sup" }]) {
      expect((await patchSession(owner.accessToken, id, body)).status).toBe(400);
    }
  });
});

describe("DELETE /api/sessions/:id", () => {
  it("removes the row and the track, idempotently, and only the owner's", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = await sessionWithTrack(owner, "public");

    expect((await deleteSession(other.accessToken, id)).status).toBe(204);
    expect((await getSession(owner.accessToken, id)).status).toBe(200);
    expect(await sessionObjects(owner.user.id, id)).toHaveLength(1);

    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
    expect((await getSession(owner.accessToken, id)).status).toBe(404);
    const row = await env.DB.prepare("select id from sessions where id = ?").bind(id).first();
    expect(row).toBeNull();

    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);
  });

  // Regression test from review of #37: a track whose upload is still in flight when the
  // session is deleted must not stay in R2.
  it("leaves no track behind when the session is deleted during the upload", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSession(owner.accessToken, id)).status).toBe(201);

    const upload = pausedUpload(owner.accessToken, id, await gzip(trackJson(id)));
    await upload.reading;

    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);
    upload.finish();

    expect((await upload.response).status).toBe(404);
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
  });

  // Review of #78, finding 3: an upload that lands while the account is being deleted (before
  // the job has removed its rows) never attaches, and its object is removed at once.
  it("removes a track that lands while the account is being deleted", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSession(owner.accessToken, id)).status).toBe(201);
    const upload = pausedUpload(owner.accessToken, id, await gzip(trackJson(id)));
    await upload.reading;
    expect((await deleteMe(owner.accessToken, { finish: false })).status).toBe(202);
    upload.finish();
    expect((await upload.response).status).toBe(401);
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
  });
});

describe("account deletion", () => {
  it("removes the user's uploaded session tracks", async () => {
    const owner = await signIn();
    const ids = [await sessionWithTrack(owner), await sessionWithTrack(owner, "public")];
    const response = await deleteMe(owner.accessToken);
    expect(response.status).toBe(202);
    for (const id of ids) expect(await sessionObjects(owner.user.id, id)).toEqual([]);
    expect((await getSession(null, ids[1] as string)).status).toBe(404);
  });

  // Regression test from review of #37: an upload still in flight when the account is
  // deleted must not leave its track in R2.
  it("leaves no track behind when the account is deleted during an upload", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSession(owner.accessToken, id)).status).toBe(201);
    const upload = pausedUpload(owner.accessToken, id, await gzip(trackJson(id)));
    await upload.reading;

    const response = await deleteMe(owner.accessToken);
    expect(response.status).toBe(202);
    upload.finish();

    // The account is gone (review of #78): the late upload is refused and leaves nothing.
    expect((await upload.response).status).toBe(401);
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
  });

  // Review of #78, finding 3: an upload that lands while the account is being deleted (before
  // the job has removed its rows) never attaches, and its object is removed at once.
  it("removes a track that lands while the account is being deleted", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSession(owner.accessToken, id)).status).toBe(201);
    const upload = pausedUpload(owner.accessToken, id, await gzip(trackJson(id)));
    await upload.reading;
    expect((await deleteMe(owner.accessToken, { finish: false })).status).toBe(202);
    upload.finish();
    expect((await upload.response).status).toBe(401);
    expect(await sessionObjects(owner.user.id, id)).toEqual([]);
  });
});

const putSessionAt = (token: string, id: string, revision: number, body: unknown = metadata()) =>
  api(`/sessions/${id}?revision=${revision}`, {
    method: "PUT",
    headers: { ...bearer(token), "content-type": "application/json" },
    body: JSON.stringify(body),
  });

const putTrackAt = (token: string, id: string, revision: number, body: BodyInit) =>
  api(`/sessions/${id}/track?revision=${revision}`, {
    method: "PUT",
    headers: { ...bearer(token), "content-type": "application/gzip" },
    body,
  });

/** A track whose content says which revision it is, to tell stored files apart. */
const trackFor = (id: string, revision: number) =>
  gzip(trackJson(id).replace('"summary":{}', `"summary":{"revision":${revision}}`));

describe("upload revisions", () => {
  it("rejects a PUT older than the stored revision", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSessionAt(owner.accessToken, id, 2)).status).toBe(201);
    expect((await putSessionAt(owner.accessToken, id, 2)).status).toBe(200);

    const stale = await putSessionAt(owner.accessToken, id, 1, metadata({ distanceM: 1 }));
    expect(stale.status).toBe(412);
    // The stored revision, so a device whose counter fell behind can continue above it.
    expect(stale.headers.get("Upload-Revision")).toBe("2");
    expect(((await stale.json()) as { error: string }).error).toBe("stale_revision");
    expect((await putSession(owner.accessToken, id)).status).toBe(412);
    const stored = (await (await getSession(owner.accessToken, id)).json()) as {
      distanceM: number;
    };
    expect(stored.distanceM).toBe(5000);

    const oldTrack = await putTrackAt(owner.accessToken, id, 1, await trackFor(id, 1));
    expect(oldTrack.status).toBe(412);
    expect(((await oldTrack.json()) as { error: string }).error).toBe("stale_revision");
    const early = await putTrackAt(owner.accessToken, id, 3, await trackFor(id, 3));
    expect(early.status).toBe(412);
    expect(early.headers.get("Upload-Revision")).toBe("2");
    expect(((await early.json()) as { error: string }).error).toBe("revision_mismatch");
    expect((await sessionObjects(owner.user.id, id)).filter((k) => k.includes(".r3."))).toEqual([]);
  });

  it("detaches and deletes the old track when a newer revision's metadata arrives", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSessionAt(owner.accessToken, id, 1)).status).toBe(201);
    expect((await putTrackAt(owner.accessToken, id, 1, await trackFor(id, 1))).status).toBe(204);
    expect(
      (await sessionObjects(owner.user.id, id)).filter((k) => k.includes(".r1.")),
    ).toHaveLength(1);

    expect((await putSessionAt(owner.accessToken, id, 2)).status).toBe(200);
    // The untrimmed track is gone before the trimmed one arrives.
    expect((await getTrack(owner.accessToken, id)).status).toBe(404);
    expect((await sessionObjects(owner.user.id, id)).filter((k) => k.includes(".r1."))).toEqual([]);

    expect((await putTrackAt(owner.accessToken, id, 2, await trackFor(id, 2))).status).toBe(204);
    const track = await getTrack(owner.accessToken, id);
    expect(await gunzip(await track.arrayBuffer())).toContain('"revision":2');
  });

  it("never lets a delayed older track upload replace a newer one", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSessionAt(owner.accessToken, id, 1)).status).toBe(201);
    const old = await trackFor(id, 1);
    let reading: () => void = () => {};
    const readingStarted = new Promise<void>((resolve) => {
      reading = resolve;
    });
    let release: () => void = () => {};
    const released = new Promise<void>((resolve) => {
      release = resolve;
    });
    let sent = false;
    const body = new ReadableStream<Uint8Array>(
      {
        async pull(controller) {
          if (!sent) {
            sent = true;
            controller.enqueue(old.slice(0, 10));
            return;
          }
          reading();
          await released;
          controller.enqueue(old.slice(10));
          controller.close();
        },
      },
      { highWaterMark: 0 },
    );
    const delayed = putTrackAt(owner.accessToken, id, 1, body);
    await readingStarted;

    expect((await putSessionAt(owner.accessToken, id, 2)).status).toBe(200);
    expect((await putTrackAt(owner.accessToken, id, 2, await trackFor(id, 2))).status).toBe(204);
    release();
    expect((await delayed).status).toBe(412);

    const track = await getTrack(owner.accessToken, id);
    expect(await gunzip(await track.arrayBuffer())).toContain('"revision":2');
    expect((await sessionObjects(owner.user.id, id)).filter((k) => k.includes(".r1."))).toEqual([]);
  });
});

describe("deleted sessions stay deleted", () => {
  it("answers 410 to a PUT for a session the caller deleted", async () => {
    const owner = await signIn();
    const id = await sessionWithTrack(owner);
    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);

    const again = await putSessionAt(owner.accessToken, id, 5);
    expect(again.status).toBe(410);
    expect(((await again.json()) as { error: string }).error).toBe("session_deleted");
    expect((await putSession(owner.accessToken, id)).status).toBe(410);
    expect((await putTrack(owner.accessToken, id, await gzip(trackJson(id)))).status).toBe(410);
    expect((await getSession(owner.accessToken, id)).status).toBe(404);
    const row = await env.DB.prepare("select id from sessions where id = ?").bind(id).first();
    expect(row).toBeNull();
  });

  it("only tombstones sessions that existed, and removes them with the account", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = crypto.randomUUID();
    // Deleting an unknown ID, by anyone, leaves nothing that blocks a first upload.
    expect((await deleteSession(other.accessToken, id)).status).toBe(204);
    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);
    const tombstones = await env.DB.prepare(
      "select count(*) as n from session_tombstones where id = ?",
    )
      .bind(id)
      .first<{ n: number }>();
    expect(tombstones?.n).toBe(0);
    expect((await putSession(owner.accessToken, id)).status).toBe(201);
    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);

    const count = () =>
      env.DB.prepare("select count(*) as n from session_tombstones where user_id = ?")
        .bind(owner.user.id)
        .first<{ n: number }>();
    expect((await count())?.n).toBe(1);
    expect((await deleteMe(owner.accessToken)).status).toBe(202);
    expect((await count())?.n).toBe(0);
  });
});

describe("concurrent metadata PUTs", () => {
  const fields = {
    sport: "kayak" as const,
    startedAt: Date.parse(START),
    endedAt: null,
    durationS: 3600,
    movingS: 3300,
    distanceM: 5000,
    maxSpeedMps: 2.4,
    avgSpeedMps: 1.52,
    summaryJson: null,
    analyzerVersion: "1.0.0",
  };

  it("never detaches a track for the same revision, even when both read the old one", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSessionAt(owner.accessToken, id, 1)).status).toBe(201);
    expect((await putTrackAt(owner.accessToken, id, 1, await trackFor(id, 1))).status).toBe(204);

    // This PUT reads revision 1; before it writes, another PUT of revision 2 and its track
    // complete. It must not clear the revision-2 track.
    let interleaved = false;
    const result = await replaceSessionMetadata(
      drizzle(env.DB),
      env.TRACKS,
      { id, userId: owner.user.id, revision: 2, fields },
      {
        afterRead: async () => {
          if (interleaved) return;
          interleaved = true;
          expect((await putSessionAt(owner.accessToken, id, 2)).status).toBe(200);
          expect((await putTrackAt(owner.accessToken, id, 2, await trackFor(id, 2))).status).toBe(
            204,
          );
        },
      },
    );
    expect(result.kind).toBe("updated");
    const track = await getTrack(owner.accessToken, id);
    expect(track.status).toBe(200);
    expect(await gunzip(await track.arrayBuffer())).toContain('"revision":2');
    expect(
      (await sessionObjects(owner.user.id, id)).filter((k) => k.includes(".r2.")),
    ).toHaveLength(1);
    expect((await sessionObjects(owner.user.id, id)).filter((k) => k.includes(".r1."))).toEqual([]);
  });

  it("keeps a detached track recorded when deleting it fails, and collects it later", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    expect((await putSessionAt(owner.accessToken, id, 1)).status).toBe(201);
    expect((await putTrackAt(owner.accessToken, id, 1, await trackFor(id, 1))).status).toBe(204);
    const old = (await rowKey(id)) as string;

    const failingDelete = new Proxy(env.TRACKS, {
      get(target, property) {
        if (property === "delete")
          return async () => Promise.reject(new Error("synthetic R2 failure"));
        const value = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const result = await replaceSessionMetadata(drizzle(env.DB), failingDelete, {
      id,
      userId: owner.user.id,
      revision: 2,
      fields,
    });
    expect(result.kind).toBe("updated");
    expect(await rowKey(id)).toBeNull();
    expect(await env.TRACKS.head(old)).not.toBeNull();
    // Recorded in the same batch that detached it, so nothing has to find it in a row.
    const recorded = await env.DB.prepare("select key from pending_r2_deletes where key = ?")
      .bind(old)
      .first();
    expect(recorded).not.toBeNull();

    expect(await collectR2Garbage(drizzle(env.DB), env.TRACKS, { userId: owner.user.id })).toBe(1);
    expect(await env.TRACKS.head(old)).toBeNull();
  });
});
