import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  createExportJob,
  EXPORT_TTL_MS,
  type ExportMessage,
  firstMessage,
  GIVE_UP_AFTER_MS,
  type PartLimits,
  partKey,
  runExportStep,
  STUCK_AFTER_MS,
  sweepExports,
} from "../src/server/lib/export-job";
import { crc32, type ZipEntry, zipStream } from "../src/server/lib/zip";
import { api, bearer, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.
const START_MS = 946720800000;

type Entry = { name: string; data: Uint8Array };

/** Reads a ZIP through its central directory, checking headers, sizes and CRC-32. */
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
    const crc = view.getUint32(at + 16, true);
    const size = view.getUint32(at + 20, true);
    const nameLength = view.getUint16(at + 28, true);
    const local = view.getUint32(at + 42, true);
    const name = decoder.decode(bytes.subarray(at + 46, at + 46 + nameLength));
    expect(view.getUint32(local, true)).toBe(0x04034b50);
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    const data = bytes.slice(start, start + size);
    expect(crc32(data), name).toBe(crc);
    entries.push({ name, data });
    at += 46 + nameLength;
  }
  return entries;
}

const text = (data: Uint8Array) => new TextDecoder().decode(data);
const parse = (entries: Entry[], name: string) => {
  const entry = entries.find((e) => e.name === name);
  if (!entry) throw new Error(`no ${name} in ${entries.map((e) => e.name).join(", ")}`);
  return JSON.parse(text(entry.data));
};

/** The storage the job uses, without the queue: tests run every step themselves. */
const manual = () => ({ DB: env.DB, TRACKS: env.TRACKS });

const sql = (query: string, ...values: unknown[]) =>
  env.DB.prepare(query)
    .bind(...values)
    .run();

async function sessionWithTrack(owner: SignIn, bytes: Uint8Array, startedAt = START_MS) {
  const id = crypto.randomUUID();
  const key = `users/${owner.user.id}/sessions/${id}/track.v1.gz`;
  const object = await env.TRACKS.put(key, bytes);
  await sql(
    "insert into sessions (id, user_id, sport, started_at, title, track_key, track_etag) values (?, ?, 'kayak', ?, 'Synthetic', ?, ?)",
    id,
    owner.user.id,
    startedAt,
    key,
    object?.etag ?? null,
  );
  return { id, key };
}

/** Runs every step of `message`'s job; returns how many steps it took. */
async function runAll(message: ExportMessage, limits?: PartLimits) {
  let next: ExportMessage | null = message;
  let steps = 0;
  while (next) {
    next = await runExportStep(manual(), next, undefined, limits);
    steps += 1;
    if (steps > 500) throw new Error("the export does not finish");
  }
  return steps;
}

async function jobRow(id: string) {
  return env.DB.prepare(
    "select status, parts_json as partsJson, cursor, total_items as total from export_jobs where id = ?",
  )
    .bind(id)
    .first<{ status: string; partsJson: string; cursor: number; total: number }>();
}

/** Every part of a finished job, read from R2 and checked as ZIPs. */
async function readParts(userId: string, exportId: string) {
  const row = await jobRow(exportId);
  const parts = JSON.parse(row?.partsJson ?? "[]") as { part: number; bytes: number }[];
  const out = new Map<number, Entry[]>();
  for (const p of parts) {
    const object = await env.TRACKS.get(partKey(userId, exportId, p.part));
    if (!object) throw new Error(`part ${p.part} is missing`);
    const bytes = new Uint8Array(await object.arrayBuffer());
    expect(bytes.length).toBe(p.bytes);
    out.set(p.part, readZip(bytes));
  }
  return out;
}

async function createManual(owner: SignIn) {
  const result = await createExportJob(manual(), owner.user.id);
  if (result.kind !== "created") throw new Error(result.kind);
  return result.job;
}

describe("account export jobs", () => {
  it("builds part 1 with a manifest of every part and file, and data parts with documents and tracks", async () => {
    const owner = await signIn({ displayName: "Navigator" });
    const other = await signIn();
    const a = await sessionWithTrack(owner, new Uint8Array([0x1f, 0x8b, 1, 2, 3]));
    const bare = crypto.randomUUID();
    await sql(
      "insert into sessions (id, user_id, sport, started_at, summary_json) values (?, ?, 'sup', ?, ?)",
      bare,
      owner.user.id,
      START_MS + 1,
      JSON.stringify({ distance: 5000 }),
    );
    await sessionWithTrack(other, new Uint8Array([9]));
    await sql(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0.001, 0.002, 500)",
      crypto.randomUUID(),
      owner.user.id,
    );
    const voyage = crypto.randomUUID();
    const leg = crypto.randomUUID();
    await sql(
      "insert into voyages (user_id, id, title, started_at) values (?, ?, 'Passage', ?)",
      owner.user.id,
      voyage,
      START_MS,
    );
    await sql(
      "insert into legs (user_id, id, voyage_id, started_at, ended_at) values (?, ?, ?, ?, ?)",
      owner.user.id,
      leg,
      voyage,
      START_MS,
      START_MS + 3600_000,
    );
    await env.TRACKS.put(
      `users/${owner.user.id}/voyages/${voyage}/legs/${leg}/track.v1.gz`,
      new Uint8Array([0x1f, 0x8b, 7]),
    );

    const job = await createManual(owner);
    expect(job.totalItems).toBe(4); // sessions file, voyages file, two tracks
    await runAll(firstMessage(job));
    expect((await jobRow(job.id))?.status).toBe("ready");

    const parts = await readParts(owner.user.id, job.id);
    expect([...parts.keys()].sort()).toEqual([1, 2]);
    const first = parts.get(1) ?? [];
    expect(first.map((e) => e.name)).toEqual([
      "README.txt",
      "account.json",
      "privacy-zones.json",
      "manifest.json",
    ]);
    expect(parse(first, "account.json")).toMatchObject({
      id: owner.user.id,
      displayName: "Navigator",
      appleUserId: expect.any(String),
    });
    expect(parse(first, "privacy-zones.json")).toEqual([
      { id: expect.any(String), lat: 0.001, lon: 0.002, radiusM: 500 },
    ]);
    const manifest = parse(first, "manifest.json");
    const data = parts.get(2) ?? [];
    expect(manifest.parts).toEqual([
      { part: 1, files: first.map((e) => ({ name: e.name })) },
      { part: 2, files: data.map((e) => ({ name: e.name })) },
    ]);
    expect(manifest.errors).toBe(0);
    expect(data.map((e) => e.name)).toEqual([
      "sessions/sessions-0001.json",
      "voyages/voyages-0001.json",
      `tracks/sessions/${a.id}.track.v1.gz`,
      `tracks/voyages/${voyage}/${leg}.track.v1.gz`,
    ]);
    const sessions = parse(data, "sessions/sessions-0001.json") as Record<string, unknown>[];
    expect(sessions.map((s) => s.id)).toEqual([a.id, bare]);
    expect(sessions[1]).toMatchObject({ summary: { distance: 5000 }, track: null });
    expect(data[2]?.data).toEqual(new Uint8Array([0x1f, 0x8b, 1, 2, 3]));
  });

  it("keeps to the snapshot while the account keeps syncing", async () => {
    const owner = await signIn();
    const edited = await sessionWithTrack(owner, new Uint8Array([1]), START_MS);
    const replaced = await sessionWithTrack(owner, new Uint8Array([2]), START_MS + 1);
    const removed = await sessionWithTrack(owner, new Uint8Array([3]), START_MS + 2);
    const deleted = await sessionWithTrack(owner, new Uint8Array([4]), START_MS + 3);
    const job = await createManual(owner);

    // After the snapshot: a new session, an edit that moves startedAt (what the paging of
    // the old design tripped over), a new track revision, a lost track and a deleted session.
    await sessionWithTrack(owner, new Uint8Array([5]), START_MS - 1000);
    await sql(
      "update sessions set started_at = ?, title = 'Edited' where id = ?",
      START_MS + 10_000,
      edited.id,
    );
    const revised = `users/${owner.user.id}/sessions/${replaced.id}/track.v1.r2.gz`;
    const object = await env.TRACKS.put(revised, new Uint8Array([2, 2]));
    await sql(
      "update sessions set track_key = ?, track_etag = ?, upload_revision = 2 where id = ?",
      revised,
      object?.etag ?? null,
      replaced.id,
    );
    await env.TRACKS.delete(replaced.key);
    await env.TRACKS.delete(removed.key);
    // Deleting a session removes its row and its objects (routes/sessions.ts).
    await sql("delete from sessions where id = ?", deleted.id);
    await env.TRACKS.delete(deleted.key);

    await runAll(firstMessage(job));
    const parts = await readParts(owner.user.id, job.id);
    const all = [...parts.values()].flat();
    const sessions = all
      .filter((e) => e.name.startsWith("sessions/"))
      .flatMap((e) => JSON.parse(text(e.data)) as { id: string; title: string }[]);
    // Exactly the snapshot's sessions that still exist, each once, with current values.
    expect(sessions.map((s) => s.id)).toEqual([edited.id, replaced.id, removed.id]);
    expect(sessions[0]?.title).toBe("Edited");
    const names = all.map((e) => e.name);
    expect(names).toContain(`tracks/sessions/${edited.id}.track.v1.gz`);
    expect(all.find((e) => e.name === `tracks/sessions/${replaced.id}.track.v1.gz`)?.data).toEqual(
      new Uint8Array([2, 2]),
    );
    expect(names).not.toContain(`tracks/sessions/${removed.id}.track.v1.gz`);

    const first = parts.get(1) ?? [];
    const errors = parse(first, "errors.json") as { file: string; reason: string }[];
    expect(errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          file: `tracks/sessions/${removed.id}.track.v1.gz`,
          reason: "missing",
        }),
        expect.objectContaining({ reason: "deleted", file: expect.stringContaining(deleted.id) }),
        expect.objectContaining({
          file: `tracks/sessions/${deleted.id}.track.v1.gz`,
          reason: "missing",
        }),
      ]),
    );
    const manifest = parse(first, "manifest.json");
    const files = manifest.parts.flatMap(
      (p: { files: { name: string; note?: string }[] }) => p.files,
    );
    expect(files.find((f: { name: string }) => f.name.includes(replaced.id))?.note).toMatch(
      /Replaced/,
    );
  });

  it("splits a large account into parts under the size cap, across many steps", async () => {
    const owner = await signIn();
    const rows = [];
    for (let i = 0; i < 520; i++) {
      const id = crypto.randomUUID();
      const key = `users/${owner.user.id}/sessions/${id}/track.v1.gz`;
      rows.push({ id, key, i });
    }
    await Promise.all(rows.map((r) => env.TRACKS.put(r.key, new Uint8Array(2000).fill(r.i % 251))));
    const statements = rows.map((r) =>
      env.DB.prepare(
        "insert into sessions (id, user_id, sport, started_at, track_key) values (?, ?, 'sup', ?, ?)",
      ).bind(r.id, owner.user.id, START_MS + r.i, r.key),
    );
    for (let i = 0; i < statements.length; i += 100)
      await env.DB.batch(statements.slice(i, i + 100));

    const job = await createManual(owner);
    expect(job.totalItems).toBe(3 + 520);
    // Each 250-session document file is about 170 KB; a part always takes its first item.
    const limits = { maxBytes: 256 * 1024, maxItems: 400, maxCalls: 700 };
    const steps = await runAll(firstMessage(job), limits);
    const parts = await readParts(owner.user.id, job.id);
    expect(parts.size).toBeGreaterThan(5);
    expect(steps).toBe(parts.size); // one part per step, part 1 last
    const row = await jobRow(job.id);
    for (const p of JSON.parse(row?.partsJson ?? "[]") as { bytes: number }[]) {
      expect(p.bytes).toBeLessThanOrEqual(limits.maxBytes);
    }
    const all = [...parts.values()].flat();
    const tracks = all.filter((e) => e.name.startsWith("tracks/"));
    expect(new Set(tracks.map((e) => e.name)).size).toBe(520);
    const sessions = all
      .filter((e) => e.name.startsWith("sessions/"))
      .flatMap((e) => JSON.parse(text(e.data)) as { id: string }[]);
    expect(sessions.map((s) => s.id)).toEqual(rows.map((r) => r.id));
    // The manifest names every file of every part.
    const manifest = parse(parts.get(1) ?? [], "manifest.json");
    const listed = manifest.parts.flatMap((p: { files: { name: string }[] }) =>
      p.files.map((f) => f.name),
    );
    expect(listed.sort()).toEqual(all.map((e) => e.name).sort());
  }, 60_000);

  it("ignores duplicate and stale messages", async () => {
    const owner = await signIn();
    await sessionWithTrack(owner, new Uint8Array([1]));
    const job = await createManual(owner);
    const message = firstMessage(job);
    const next = await runExportStep(manual(), message);
    expect(next).not.toBeNull();
    // Redelivered: the job has moved on, so nothing happens.
    expect(await runExportStep(manual(), message)).toBeNull();
    expect(await runAll(next as ExportMessage)).toBe(1);
    expect((await jobRow(job.id))?.status).toBe("ready");
  });

  it("allows one export at a time and a few a day", async () => {
    const owner = await signIn();
    const first = await createExportJob(manual(), owner.user.id);
    expect(first.kind).toBe("created");
    const again = await createExportJob(manual(), owner.user.id);
    expect(again).toMatchObject({ kind: "in_progress" });
    if (first.kind !== "created") return;
    await runAll(firstMessage(first.job));
    for (let i = 0; i < 2; i++) {
      const next = await createExportJob(manual(), owner.user.id);
      if (next.kind !== "created") throw new Error(next.kind);
      await runAll(firstMessage(next.job));
    }
    expect((await createExportJob(manual(), owner.user.id)).kind).toBe("rate_limited");
  });

  it("expires finished exports, resumes stuck ones and fails hopeless ones", async () => {
    const owner = await signIn();
    await sessionWithTrack(owner, new Uint8Array([1]));
    const done = await createManual(owner);
    await runAll(firstMessage(done));
    const stuck = await createExportJob(manual(), owner.user.id);
    if (stuck.kind !== "created") throw new Error(stuck.kind);

    // The queued job's message was lost: the sweep resumes it (inline, without a queue).
    const later = Date.now() + STUCK_AFTER_MS + 1000;
    const resumed = await sweepExports(manual(), null, later);
    expect(resumed.resumed).toBeGreaterThanOrEqual(1);
    expect((await jobRow(stuck.job.id))?.status).toBe("ready");

    const expired = await sweepExports(manual(), null, Date.now() + EXPORT_TTL_MS + 1000);
    expect(expired.expired).toBeGreaterThanOrEqual(2);
    expect((await jobRow(done.id))?.status).toBe("expired");
    expect(
      (await env.TRACKS.list({ prefix: `users/${owner.user.id}/exports/${done.id}/` })).objects,
    ).toHaveLength(0);

    const hopeless = await signIn();
    const old = await createExportJob(
      manual(),
      hopeless.user.id,
      Date.now() - GIVE_UP_AFTER_MS - 1,
    );
    if (old.kind !== "created") throw new Error(old.kind);
    const failed = await sweepExports(manual(), null, Date.now() + STUCK_AFTER_MS);
    expect(failed.failed).toBeGreaterThanOrEqual(1);
    expect((await jobRow(old.job.id))?.status).toBe("failed");
  });

  it("stops and cleans up when the account is deleted during the export", async () => {
    const owner = await signIn();
    await sessionWithTrack(owner, new Uint8Array([1]));
    const job = await createManual(owner);
    const next = await runExportStep(manual(), firstMessage(job));
    expect(next).not.toBeNull();
    await sql("update users set deleted_at = ? where id = ?", Date.now(), owner.user.id);
    expect(await runExportStep(manual(), next as ExportMessage)).toBeNull();
    expect((await jobRow(job.id))?.status).toBe("failed");
    expect(
      (await env.TRACKS.list({ prefix: `users/${owner.user.id}/exports/` })).objects,
    ).toHaveLength(0);
  });
});

describe("/api/me/exports", () => {
  const poll = async (token: string, id: string) => {
    for (let i = 0; i < 100; i++) {
      const response = await api(`/me/exports/${id}`, { headers: bearer(token) });
      const body = (await response.json()) as {
        status: string;
        parts: { part: number; url: string; bytes: number }[];
      };
      if (body.status !== "queued" && body.status !== "building") return body;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("the export never finished");
  };

  it("starts an export on the queue, reports it and serves its parts to the owner only", async () => {
    const owner = await signIn();
    const stranger = await signIn();
    await sessionWithTrack(owner, new Uint8Array([0x1f, 0x8b, 4, 2]));
    const started = await api("/me/exports", {
      method: "POST",
      headers: bearer(owner.accessToken),
    });
    expect(started.status).toBe(202);
    expect(started.headers.get("cache-control")).toBe("private, no-store");
    const { id } = (await started.json()) as { id: string };

    const again = await api("/me/exports", { method: "POST", headers: bearer(owner.accessToken) });
    if (again.status === 409) expect(await again.json()).toMatchObject({ message: id });

    const ready = await poll(owner.accessToken, id);
    expect(ready.status).toBe("ready");
    expect(ready.parts.map((p) => p.part)).toEqual([1, 2]);

    const list = await api("/me/exports", { headers: bearer(owner.accessToken) });
    expect(((await list.json()) as { exports: { id: string }[] }).exports[0]?.id).toBe(id);

    const part = await api(ready.parts[1]?.url ?? "", { headers: bearer(owner.accessToken) });
    expect(part.status).toBe(200);
    expect(part.headers.get("content-type")).toBe("application/zip");
    expect(part.headers.get("cache-control")).toBe("private, no-store");
    expect(part.headers.get("content-disposition")).toMatch(
      /^attachment; filename="madegood-export-/,
    );
    const entries = readZip(new Uint8Array(await part.arrayBuffer()));
    expect(entries.map((e) => e.name)).toContain("sessions/sessions-0001.json");

    for (const path of [`/me/exports/${id}`, ready.parts[0]?.url ?? ""]) {
      expect((await api(path, { headers: bearer(stranger.accessToken) })).status).toBe(404);
      expect((await api(path)).status).toBe(401);
    }
    expect((await api("/me/exports", { method: "POST" })).status).toBe(401);
    expect(
      (await api(`/me/exports/${id}/parts/9`, { headers: bearer(owner.accessToken) })).status,
    ).toBe(404);
  });

  it("refuses a part of an export that is still building", async () => {
    const owner = await signIn();
    const job = await createManual(owner);
    const response = await api(`/me/exports/${job.id}/parts/1`, {
      headers: bearer(owner.accessToken),
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: "export_not_ready" });
  });
});

describe("ZIP writer", () => {
  const collect = async (stream: AsyncIterable<Uint8Array>) => {
    const parts: Uint8Array[] = [];
    for await (const part of stream) parts.push(part);
    return new Uint8Array(await new Blob(parts).arrayBuffer());
  };

  it("writes stored entries a reader accepts, streams included, and skips missing ones", async () => {
    const big = new Uint8Array(200_000).map((_, i) => i % 251);
    const entries: ZipEntry[] = [
      { name: "a.txt", data: async () => new TextEncoder().encode("hello") },
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
    ];
    const zip = readZip(await collect(zipStream(entries, new Date(START_MS))));
    expect(zip.map((e) => e.name)).toEqual(["a.txt", "dir/stream.bin"]);
    expect(zip[1]?.data).toEqual(big);
    expect(crc32(new TextEncoder().encode("123456789"))).toBe(0xcbf43926);
  });
});
