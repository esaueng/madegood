import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { crc32, type ZipEntry, zipStream } from "../src/server/lib/zip";
import {
  EXPORT_MAX_TRACK_BYTES,
  EXPORT_MAX_TRACKS,
  exportTooLarge,
} from "../src/server/routes/export";
import { api, bearer, signIn } from "./apple";

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

describe("GET /api/me/export", () => {
  it("returns the account's data and owner tracks, and nobody else's", async () => {
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
    // Stored directly: the export passes stored bytes through without parsing them.
    const key = `users/${session.user.id}/sessions/${id}/track.v1.gz`;
    await env.TRACKS.put(key, trackBytes);
    await env.DB.prepare("update sessions set track_key = ? where id = ?").bind(key, id).run();
    // A session with no track, and another user's session that must not appear.
    const bare = crypto.randomUUID();
    await env.DB.prepare(
      "insert into sessions (id, user_id, sport, started_at) values (?, ?, 'sup', 946720800000)",
    )
      .bind(bare, session.user.id)
      .run();
    await env.DB.prepare(
      "insert into sessions (id, user_id, sport, started_at) values (?, ?, 'sup', 946720800000)",
    )
      .bind(crypto.randomUUID(), other.user.id)
      .run();
    await env.DB.prepare(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0.001, 0.002, 500)",
    )
      .bind(crypto.randomUUID(), session.user.id)
      .run();
    // A private voyage with one leg and its track.
    const voyage = crypto.randomUUID();
    const leg = crypto.randomUUID();
    await env.DB.prepare(
      "insert into voyages (user_id, id, title, started_at) values (?, ?, 'Passage', 946720800000)",
    )
      .bind(session.user.id, voyage)
      .run();
    await env.DB.prepare(
      "insert into legs (user_id, id, voyage_id, started_at, ended_at) values (?, ?, ?, 946720800000, 946724400000)",
    )
      .bind(session.user.id, leg, voyage)
      .run();
    const legBytes = new Uint8Array([0x1f, 0x8b, 9, 9]);
    await env.TRACKS.put(
      `users/${session.user.id}/voyages/${voyage}/legs/${leg}/track.v1.gz`,
      legBytes,
    );

    const response = await api("/me/export", { headers: bearer(session.accessToken) });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/zip");
    expect(response.headers.get("content-disposition")).toMatch(
      /^attachment; filename="madegood-export-\d{4}-\d\d-\d\d\.zip"$/,
    );
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    const zip = readZip(new Uint8Array(await response.arrayBuffer()));
    expect(zip.map((e) => e.name).sort()).toEqual(
      [
        "README.txt",
        "account.json",
        "privacy-zones.json",
        "sessions.json",
        "voyages.json",
        `tracks/sessions/${id}.track.v1.gz`,
        `tracks/voyages/${voyage}/${leg}.track.v1.gz`,
      ].sort(),
    );

    expect(parse(zip, "account.json")).toMatchObject({
      id: session.user.id,
      handle: session.user.handle,
      displayName: "Navigator",
      units: "nautical",
      defaultVisibility: "private",
      appleUserId: expect.any(String),
    });
    const sessions = parse(zip, "sessions.json") as Record<string, unknown>[];
    expect(sessions.map((s) => s.id).sort()).toEqual([id, bare].sort());
    const full = sessions.find((s) => s.id === id);
    // The owner's full summary, not the shared projection.
    expect(full).toMatchObject({
      sport: "kayak",
      startedAt: START,
      distanceM: 5000,
      summary: { distance: 5000, heartRateMax: 150 },
      track: `tracks/sessions/${id}.track.v1.gz`,
    });
    expect(sessions.find((s) => s.id === bare)?.track).toBeNull();
    expect(parse(zip, "privacy-zones.json")).toEqual([
      { id: expect.any(String), lat: 0.001, lon: 0.002, radiusM: 500 },
    ]);
    expect(parse(zip, "voyages.json")).toEqual([
      expect.objectContaining({
        id: voyage,
        title: "Passage",
        legs: [expect.objectContaining({ id: leg })],
      }),
    ]);
    expect(zip.find((e) => e.name.startsWith("tracks/sessions/"))?.data).toEqual(trackBytes);
    expect(zip.find((e) => e.name.startsWith("tracks/voyages/"))?.data).toEqual(legBytes);
  });

  it("answers HEAD (the website's pre-check) without a body", async () => {
    const session = await signIn();
    const head = await api("/me/export", { method: "HEAD", headers: bearer(session.accessToken) });
    expect(head.status).toBe(200);
    expect(head.headers.get("content-type")).toBe("application/zip");
    expect((await head.arrayBuffer()).byteLength).toBe(0);
    expect((await api("/me/export", { method: "HEAD" })).status).toBe(401);
  });

  it("is refused without a sign-in, and after the account is deleted", async () => {
    expect((await api("/me/export")).status).toBe(401);
    const session = await signIn();
    await api("/me", { method: "DELETE", headers: bearer(session.accessToken) });
    expect((await api("/me/export", { headers: bearer(session.accessToken) })).status).toBe(401);
  });

  it("refuses an export over the track count or size limit", () => {
    expect(exportTooLarge(0, 0)).toBe(false);
    expect(exportTooLarge(EXPORT_MAX_TRACKS, EXPORT_MAX_TRACK_BYTES)).toBe(false);
    expect(exportTooLarge(EXPORT_MAX_TRACKS + 1, 0)).toBe(true);
    expect(exportTooLarge(1, EXPORT_MAX_TRACK_BYTES + 1)).toBe(true);
  });
});
