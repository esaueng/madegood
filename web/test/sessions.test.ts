import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { api, bearer, type SignIn, signIn } from "./apple";

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

const trackKey = (userId: string, id: string) => `users/${userId}/sessions/${id}/track.v1.gz`;

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
    const object = await env.TRACKS.get(trackKey(owner.user.id, id));
    expect(object?.httpMetadata?.contentType).toBe("application/gzip");
    expect(new Uint8Array(await (object as R2ObjectBody).arrayBuffer())).toEqual(file);
    const listed = await env.TRACKS.list({ prefix: `users/${owner.user.id}/` });
    expect(listed.objects).toHaveLength(1);

    const session = await (await getSession(owner.accessToken, id)).json();
    expect(session).toMatchObject({ hasTrack: true });
    const row = await env.DB.prepare("select track_key from sessions where id = ?")
      .bind(id)
      .first<{ track_key: string }>();
    expect(row?.track_key).toBe(trackKey(owner.user.id, id));
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
    expect(await env.TRACKS.head(trackKey(other.user.id, id))).toBeNull();
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();
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
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();

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
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();
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

  it("withholds tracks from others while the owner has a privacy zone", async () => {
    const owner = await signIn();
    const other = await signIn();
    const id = await sessionWithTrack(owner, "public");
    await env.DB.prepare(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0, 0, 200)",
    )
      .bind(crypto.randomUUID(), owner.user.id)
      .run();

    for (const token of [other.accessToken, null]) {
      expect((await getSession(token, id)).status).toBe(200);
      const track = await getTrack(token, id);
      expect(track.status).toBe(403);
      expect(await track.json()).toMatchObject({ error: "forbidden" });
    }
    expect((await getTrack(owner.accessToken, id)).status).toBe(200);
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
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).not.toBeNull();

    expect((await deleteSession(owner.accessToken, id)).status).toBe(204);
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();
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
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();
  });
});

describe("account deletion", () => {
  it("removes the user's uploaded session tracks", async () => {
    const owner = await signIn();
    const ids = [await sessionWithTrack(owner), await sessionWithTrack(owner, "public")];
    const response = await api("/me", { method: "DELETE", headers: bearer(owner.accessToken) });
    expect(response.status).toBe(204);
    for (const id of ids) expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();
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

    const response = await api("/me", { method: "DELETE", headers: bearer(owner.accessToken) });
    expect(response.status).toBe(204);
    upload.finish();

    expect((await upload.response).status).toBe(404);
    expect(await env.TRACKS.head(trackKey(owner.user.id, id))).toBeNull();
  });
});
