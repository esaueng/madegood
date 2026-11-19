import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { describe, expect, it } from "vitest";
import { crc32, type ZipEntry, zipStream } from "../src/server/lib/zip";
import {
  type ExportError,
  jsonArray,
  PartBudget,
  planParts,
  readTrack,
  sessionPages,
  TRACKS_PER_PART,
} from "../src/server/routes/export";
import { api, bearer, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.
const START = "2000-01-01T10:00:00.000Z";

type Entry = { name: string; data: Uint8Array };

/**
 * Reads a ZIP through its central directory, checking each local header, stored size and
 * CRC-32 the way an unzip tool does.
 */
function readZip(bytes: Uint8Array): Entry[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const end = bytes.length - 22;
  expect(view.getUint32(end, true)).toBe(0x06054b50);
  const count = view.getUint16(end + 10, true);
  const directorySize = view.getUint32(end + 12, true);
  let at = view.getUint32(end + 16, true);
  expect(at + directorySize).toBe(end);
  const decoder = new TextDecoder();
  const entries: Entry[] = [];
  for (let i = 0; i < count; i++) {
    expect(view.getUint32(at, true)).toBe(0x02014b50);
    expect(view.getUint16(at + 10, true)).toBe(0); // stored
    const crc = view.getUint32(at + 16, true);
    const size = view.getUint32(at + 20, true);
    expect(view.getUint32(at + 24, true)).toBe(size);
    const nameLength = view.getUint16(at + 28, true);
    const local = view.getUint32(at + 42, true);
    const name = decoder.decode(bytes.subarray(at + 46, at + 46 + nameLength));
    expect(view.getUint32(local, true)).toBe(0x04034b50);
    const localName = view.getUint16(local + 26, true);
    const start = local + 30 + localName + view.getUint16(local + 28, true);
    const data = bytes.slice(start, start + size);
    expect(crc32(data), name).toBe(crc);
    // The data descriptor repeats the CRC and sizes.
    expect(view.getUint32(start + size, true)).toBe(0x08074b50);
    expect(view.getUint32(start + size + 4, true)).toBe(crc);
    entries.push({ name, data });
    at += 46 + nameLength;
  }
  return entries;
}

async function collect(stream: AsyncIterable<Uint8Array>): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  for await (const part of stream) parts.push(part);
  return new Uint8Array(await new Blob(parts).arrayBuffer());
}

const text = (data: Uint8Array) => new TextDecoder().decode(data);
const parse = (entries: Entry[], name: string) => {
  const entry = entries.find((e) => e.name === name);
  if (!entry) throw new Error(`no ${name}`);
  return JSON.parse(text(entry.data));
};

describe("ZIP writer", () => {
  it("writes stored entries a reader accepts, streams included, and skips missing ones", async () => {
    const big = new Uint8Array(200_000).map((_, i) => i % 251);
    const entries: ZipEntry[] = [
      { name: "a.txt", data: async () => new TextEncoder().encode("hello") },
      { name: "empty", data: async () => new Uint8Array() },
      { name: "gone.gz", data: async () => null },
      {
        name: "dir/stream.bin",
        data: async () =>
          new ReadableStream({
            start(controller) {
              controller.enqueue(big.subarray(0, 70_000));
              controller.enqueue(big.subarray(70_000));
              controller.close();
            },
          }),
      },
      { name: "ünïcode.json", data: async () => new TextEncoder().encode("{}") },
    ];
    const zip = readZip(await collect(zipStream(entries, new Date(START))));
    expect(zip.map((e) => e.name)).toEqual(["a.txt", "empty", "dir/stream.bin", "ünïcode.json"]);
    expect(text(zip[0]?.data ?? new Uint8Array())).toBe("hello");
    expect(zip[2]?.data).toEqual(big);
  });

  it("writes a valid empty archive", async () => {
    expect(readZip(await collect(zipStream([], new Date(START))))).toEqual([]);
  });

  it("computes the standard CRC-32", () => {
    expect(crc32(new TextEncoder().encode("123456789"))).toBe(0xcbf43926);
  });
});

type Manifest = {
  trackCount: number;
  parts: { part: number; url: string; contents: string; tracks: number; filename: string }[];
};

const get = (token: string, path: string, init: RequestInit = {}) =>
  api(path, { ...init, headers: { ...bearer(token), ...(init.headers as object) } });

async function manifest(token: string): Promise<Manifest> {
  const response = await get(token, "/me/export");
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  return (await response.json()) as Manifest;
}

async function part(token: string, url: string): Promise<Entry[]> {
  const response = await get(token, url);
  expect(response.status, url).toBe(200);
  expect(response.headers.get("content-type")).toBe("application/zip");
  return readZip(new Uint8Array(await response.arrayBuffer()));
}

const sql = (query: string, ...values: unknown[]) =>
  env.DB.prepare(query)
    .bind(...values)
    .run();

/** A session row with a track object at revision `revision`. */
async function sessionWithTrack(session: SignIn, bytes: Uint8Array, startedAt = 946720800000) {
  const id = crypto.randomUUID();
  const key = `users/${session.user.id}/sessions/${id}/track.v1.gz`;
  await env.TRACKS.put(key, bytes);
  await sql(
    "insert into sessions (id, user_id, sport, started_at, track_key) values (?, ?, 'kayak', ?, ?)",
    id,
    session.user.id,
    startedAt,
    key,
  );
  return { id, key };
}

describe("GET /api/me/export", () => {
  it("lists the parts, and the parts hold the account's data and owner tracks only", async () => {
    const session = await signIn({ displayName: "Navigator" });
    const other = await signIn();
    const id = crypto.randomUUID();
    const put = await api(`/sessions/${id}`, {
      method: "PUT",
      headers: { ...bearer(session.accessToken), "content-type": "application/json" },
      body: JSON.stringify({
        sport: "kayak",
        startedAt: START,
        endedAt: "2000-01-01T11:00:00.000Z",
        distanceM: 5000,
        summary: { distance: 5000, heartRateMax: 150 },
      }),
    });
    expect(put.status).toBe(201);
    const trackBytes = new Uint8Array([0x1f, 0x8b, 1, 2, 3, 4, 5]);
    const key = `users/${session.user.id}/sessions/${id}/track.v1.gz`;
    await env.TRACKS.put(key, trackBytes);
    await sql("update sessions set track_key = ? where id = ?", key, id);
    const bare = crypto.randomUUID();
    await sql(
      "insert into sessions (id, user_id, sport, started_at) values (?, ?, 'sup', 946720800000)",
      bare,
      session.user.id,
    );
    await sessionWithTrack(other, new Uint8Array([9]));
    await sql(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0.001, 0.002, 500)",
      crypto.randomUUID(),
      session.user.id,
    );
    const voyage = crypto.randomUUID();
    const leg = crypto.randomUUID();
    await sql(
      "insert into voyages (user_id, id, title, started_at) values (?, ?, 'Passage', 946720800000)",
      session.user.id,
      voyage,
    );
    await sql(
      "insert into legs (user_id, id, voyage_id, started_at, ended_at) values (?, ?, ?, 946720800000, 946724400000)",
      session.user.id,
      leg,
      voyage,
    );
    const legBytes = new Uint8Array([0x1f, 0x8b, 9, 9]);
    await env.TRACKS.put(
      `users/${session.user.id}/voyages/${voyage}/legs/${leg}/track.v1.gz`,
      legBytes,
    );

    const plan = await manifest(session.accessToken);
    expect(plan.trackCount).toBe(2);
    expect(plan.parts.map((p) => [p.part, p.contents, p.tracks])).toEqual([
      [1, "account", 0],
      [2, "tracks", 2],
    ]);

    const account = await part(session.accessToken, plan.parts[0]?.url ?? "");
    expect(account.map((e) => e.name)).toEqual([
      "README.txt",
      "account.json",
      "sessions.json",
      "privacy-zones.json",
      "voyages.json",
    ]);
    expect(parse(account, "account.json")).toMatchObject({
      id: session.user.id,
      handle: session.user.handle,
      displayName: "Navigator",
      units: "nautical",
      appleUserId: expect.any(String),
    });
    const sessions = parse(account, "sessions.json") as Record<string, unknown>[];
    expect(sessions.map((s) => s.id).sort()).toEqual([id, bare].sort());
    expect(sessions.find((s) => s.id === id)).toMatchObject({
      sport: "kayak",
      startedAt: START,
      summary: { distance: 5000, heartRateMax: 150 },
      track: `tracks/sessions/${id}.track.v1.gz`,
    });
    expect(parse(account, "privacy-zones.json")).toEqual([
      { id: expect.any(String), lat: 0.001, lon: 0.002, radiusM: 500 },
    ]);
    expect(parse(account, "voyages.json")).toEqual([
      expect.objectContaining({ id: voyage, legs: [expect.objectContaining({ id: leg })] }),
    ]);

    const tracks = await part(session.accessToken, plan.parts[1]?.url ?? "");
    expect(tracks.map((e) => e.name)).toEqual([
      `tracks/sessions/${id}.track.v1.gz`,
      `tracks/voyages/${voyage}/${leg}.track.v1.gz`,
    ]);
    expect(tracks[0]?.data).toEqual(trackBytes);
    expect(tracks[1]?.data).toEqual(legBytes);
  });

  it("writes empty documents and no track parts for an empty account", async () => {
    const session = await signIn();
    const plan = await manifest(session.accessToken);
    expect(plan.parts).toHaveLength(1);
    const account = await part(session.accessToken, plan.parts[0]?.url ?? "");
    expect(parse(account, "sessions.json")).toEqual([]);
    expect(parse(account, "voyages.json")).toEqual([]);
  });

  it("streams sessions.json page by page, with large summaries", async () => {
    const session = await signIn();
    // 260 sessions with ~60 KiB summaries: about 15 MiB of JSON, two D1 pages.
    const blob = "x".repeat(60 * 1024);
    const rows = Array.from({ length: 260 }, (_, i) =>
      env.DB.prepare(
        "insert into sessions (id, user_id, sport, started_at, summary_json) values (?, ?, 'sup', ?, ?)",
      ).bind(
        crypto.randomUUID(),
        session.user.id,
        946720800000 + i,
        JSON.stringify({ n: i, blob }),
      ),
    );
    for (let i = 0; i < rows.length; i += 50) await env.DB.batch(rows.slice(i, i + 50));

    // The writer holds one page of rows at a time: each chunk is one page's JSON.
    const db = drizzle(env.DB);
    const chunks: number[] = [];
    let pages = 0;
    for await (const page of sessionPages(db, session.user.id, 50)) {
      pages += 1;
      expect(page.length).toBeLessThanOrEqual(50);
    }
    for await (const chunk of jsonArray(sessionPages(db, session.user.id, 50))) {
      chunks.push(chunk.length);
    }
    expect(pages).toBe(6);
    expect(chunks).toHaveLength(pages + 2);
    expect(Math.max(...chunks)).toBeLessThan(50 * 62 * 1024);

    const plan = await manifest(session.accessToken);
    const account = await part(session.accessToken, plan.parts[0]?.url ?? "");
    const sessions = parse(account, "sessions.json") as { summary: { n: number; blob: string } }[];
    expect(sessions).toHaveLength(260);
    expect(sessions.map((s) => s.summary.n)).toEqual(Array.from({ length: 260 }, (_, i) => i));
    expect(sessions.every((s) => s.summary.blob.length === blob.length)).toBe(true);
  });

  it("exports the current revision of a track replaced after the manifest", async () => {
    const session = await signIn();
    const { id, key } = await sessionWithTrack(session, new Uint8Array([1, 1, 1]));
    const sameKey = await sessionWithTrack(session, new Uint8Array([2, 2, 2]), 946720900000);
    const plan = await manifest(session.accessToken);

    // A new upload revision: new key, old object deleted (routes/sessions.ts).
    const revised = `users/${session.user.id}/sessions/${id}/track.v1.r2.gz`;
    await env.TRACKS.put(revised, new Uint8Array([1, 2, 3, 4]));
    await sql("update sessions set track_key = ?, upload_revision = 2 where id = ?", revised, id);
    await env.TRACKS.delete(key);
    // The same revision uploaded again: same key, new ETag.
    await env.TRACKS.put(sameKey.key, new Uint8Array([2, 3]));

    const tracks = await part(session.accessToken, plan.parts[1]?.url ?? "");
    expect(tracks.map((e) => e.name)).toEqual([
      `tracks/sessions/${id}.track.v1.gz`,
      `tracks/sessions/${sameKey.id}.track.v1.gz`,
    ]);
    expect(tracks[0]?.data).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(tracks[1]?.data).toEqual(new Uint8Array([2, 3]));
  });

  it("lists a track that vanished during the export in errors.json", async () => {
    const session = await signIn();
    const kept = await sessionWithTrack(session, new Uint8Array([1]));
    const lost = await sessionWithTrack(session, new Uint8Array([2]), 946720900000);
    const plan = await manifest(session.accessToken);
    await env.TRACKS.delete(lost.key);

    const tracks = await part(session.accessToken, plan.parts[1]?.url ?? "");
    expect(tracks.map((e) => e.name)).toEqual([
      `tracks/sessions/${kept.id}.track.v1.gz`,
      "errors.json",
    ]);
    expect(parse(tracks, "errors.json")).toEqual([
      expect.objectContaining({
        file: `tracks/sessions/${lost.id}.track.v1.gz`,
        reason: "missing",
      }),
    ]);
  });

  it("refuses a part whose track list changed (409) or whose range is invalid (400)", async () => {
    const session = await signIn();
    await sessionWithTrack(session, new Uint8Array([1]));
    const plan = await manifest(session.accessToken);
    const url = plan.parts[1]?.url ?? "";
    expect((await get(session.accessToken, url.replace(/to=\d+/, "to=0"))).status).toBe(400);
    expect((await get(session.accessToken, url.replace(/to=\d+/, "to=5"))).status).toBe(400);
    expect((await get(session.accessToken, "/me/export?part=2")).status).toBe(400);

    await sessionWithTrack(session, new Uint8Array([2]), 946720900000);
    const changed = await get(session.accessToken, url);
    expect(changed.status).toBe(409);
    expect(await changed.json()).toMatchObject({ error: "export_changed" });
  });

  it("answers HEAD for a part (the website's pre-check) without a body", async () => {
    const session = await signIn();
    await sessionWithTrack(session, new Uint8Array([1]));
    const plan = await manifest(session.accessToken);
    for (const p of plan.parts) {
      const head = await get(session.accessToken, p.url, { method: "HEAD" });
      expect(head.status).toBe(200);
      expect(head.headers.get("content-type")).toBe("application/zip");
      expect((await head.arrayBuffer()).byteLength).toBe(0);
    }
    expect((await api("/me/export", { method: "HEAD" })).status).toBe(401);
  });

  it("is refused without a sign-in, and after the account is deleted", async () => {
    expect((await api("/me/export")).status).toBe(401);
    expect((await api("/me/export?part=1")).status).toBe(401);
    const session = await signIn();
    await api("/me", { method: "DELETE", headers: bearer(session.accessToken) });
    expect((await get(session.accessToken, "/me/export")).status).toBe(401);
  });
});

describe("export parts", () => {
  it("plans at most TRACKS_PER_PART tracks and about PART_TARGET_BYTES per part", () => {
    expect(planParts([])).toEqual([]);
    const counts = planParts(Array(450).fill(1)).map((p) => p.to - p.from);
    expect(counts).toEqual([TRACKS_PER_PART, TRACKS_PER_PART, 50]);
    const mib = 1024 * 1024;
    expect(planParts([200 * mib, 100 * mib, 8 * mib, 300 * mib])).toEqual([
      { from: 0, to: 1, bytes: 200 * mib },
      { from: 1, to: 3, bytes: 108 * mib },
      { from: 3, to: 4, bytes: 300 * mib },
    ]);
  });

  it("stops at the bytes actually read and at the call budget, and says so", async () => {
    const session = await signIn();
    const { id, key } = await sessionWithTrack(session, new Uint8Array(10));
    const context = { db: drizzle(env.DB), bucket: env.TRACKS, userId: session.user.id };
    const listed = await env.TRACKS.head(key);
    // Listed at 10 bytes, but overwritten with 30 since: the 30 count.
    await env.TRACKS.put(key, new Uint8Array(30));
    const ref = {
      name: `tracks/sessions/${id}.track.v1.gz`,
      key,
      sessionId: id,
      etag: listed?.etag,
      size: 10,
    };
    const errors: ExportError[] = [];
    const small = new PartBudget(10, 20);
    expect(await readTrack(ref, context, small, errors)).toBeNull();
    expect(small.bytes).toBe(0);
    expect(errors).toEqual([expect.objectContaining({ reason: "part_size_limit" })]);

    const roomy = new PartBudget(10, 40);
    const body = await readTrack(ref, context, roomy, errors);
    expect(new Uint8Array(await new Response(body).arrayBuffer())).toHaveLength(30);
    expect(roomy.bytes).toBe(30);
    // ETag mismatch: the conditional read, the row and the unconditional read.
    expect(roomy.calls).toBe(3);

    const spent = new PartBudget(0, 40);
    expect(await readTrack(ref, context, spent, errors)).toBeNull();
    expect(errors.at(-1)).toMatchObject({ reason: "request_budget" });
  });
});
