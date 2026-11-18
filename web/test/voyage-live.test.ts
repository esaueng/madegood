import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createApp } from "../src/server/app";
import type { VoyageViewerState } from "../src/server/lib/voyage-sharing";
import { liveVoyage } from "../src/server/live/registry";
import type { Position } from "../src/server/live/voyage-live";
import { api, bearer, postJson, signIn } from "./apple";

const unavailable = { status: "unavailable" };
const position = (
  capturedAtMs: number,
  lon: number,
  segmentId = crypto.randomUUID(),
): Position => ({
  sampleId: crypto.randomUUID(),
  segmentId,
  capturedAtMs,
  lat: 0,
  lon,
});
const viewerFix = ({ lat, lon, capturedAtMs }: Position) => ({ lat, lon, capturedAtMs });
const shareURL = (slug: string) => `/live/${slug}`;
const snapshot = async (slug: string) => (await api(shareURL(slug))).json();

async function setup(voyageId: string = crypto.randomUUID(), completed = false) {
  const user = await signIn();
  const headers = bearer(user.accessToken);
  const path = `/voyages/${voyageId}`;
  const stub = liveVoyage(env, { userId: user.user.id, voyageId });
  const response = await api(path, {
    method: "PUT",
    headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({
      title: "Synthetic Private Passage",
      boatName: "Synthetic Private Hull",
      startedAt: "2026-01-01T00:00:00Z",
      ...(completed ? { endedAt: "2026-01-02T00:00:00Z" } : {}),
    }),
  });
  expect(response.status).toBe(201);
  const share = (body: unknown) => postJson(`${path}/sharing`, body, headers);
  const state = () => api(`${path}/sharing`, { headers });
  let generation = 1;
  const ingest = (positions: Position[], grantGeneration = generation) =>
    postJson(`${path}/positions`, { grantGeneration, positions }, headers);
  const remove = () => api("/me", { method: "DELETE", headers });
  async function issue(delayS = 0, expiresInS = 1200) {
    const result = await share({ action: "issue", delayS, expiresInS });
    expect(result.status).toBe(200);
    const body = await result.json<{ slug: string; grantGeneration: number }>();
    expect(body.slug).toMatch(/^[a-zA-Z0-9_-]{43}$/);
    generation = body.grantGeneration;
    return body.slug;
  }
  return {
    headers,
    path,
    voyageId,
    stub,
    userId: user.user.id,
    share,
    state,
    ingest,
    remove,
    issue,
  };
}

function clock() {
  // Keep actual workerd timers in the future. Execute stored alarms with the test driver.
  const start = Date.now() + 60_000;
  let now = start;
  vi.spyOn(Date, "now").mockImplementation(() => now);
  return {
    start,
    at: (elapsed: number) => {
      now = start + elapsed;
    },
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

const openSockets = new Set<WebSocket>();
async function connect(slug: string) {
  const response = await api(shareURL(slug), { headers: { Upgrade: "websocket" } });
  expect(response.status).toBe(101);
  expect(response.headers.get("Cache-Control")).toBe("private, no-store");
  const ws = response.webSocket;
  if (!ws) throw new Error("No client WebSocket");
  openSockets.add(ws);
  const messages: VoyageViewerState[] = [];
  const closed = deferred<number>();
  let consumed = 0;
  let signal = deferred<void>();
  ws.addEventListener("message", ({ data }) => {
    messages.push(JSON.parse(String(data)));
    signal.resolve();
    signal = deferred();
  });
  ws.addEventListener("close", ({ code }) => {
    openSockets.delete(ws);
    closed.resolve(code);
  });
  ws.accept();
  async function next() {
    if (consumed === messages.length) await signal.promise;
    return messages[consumed++];
  }
  return { ws, next, messages, closed: closed.promise };
}

async function alarmAt(stub: ReturnType<typeof liveVoyage>) {
  return runInDurableObject(stub, (_, state) => state.storage.getAlarm());
}

afterEach(() => {
  for (const ws of openSockets) ws.close(1000);
  openSockets.clear();
  vi.spyOn(Date, "now").mockRestore();
});

describe("local voyage transport", () => {
  it("keeps viewer routes unavailable in a preview without a live namespace", async () => {
    const previewEnv = { ...env, VOYAGE_LIVE_LOCAL: "1" };
    Reflect.deleteProperty(previewEnv, "VOYAGE_LIVE");
    const app = createApp();
    const slug = "a".repeat(43);
    for (const path of [`/v/${slug}`, `/api/live/${slug}`]) {
      const response = await app.request(path, {}, previewEnv);
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
    }
  });

  it("keeps the completed path independent and atomically deduplicates active sample receipts", async () => {
    const a = await setup();
    const stranger = await signIn();
    const b = await setup(a.voyageId);
    const completed = await setup(undefined, true);
    const time = clock();
    const sample = position(time.start + 1, 0.1);
    const later = position(time.start + 1, 0.2);
    expect(await (await a.state()).json()).toEqual({
      sharing: "off",
      delayS: 0,
      preview: unavailable,
    });
    expect((await api(`${a.path}/sharing`)).status).toBe(401);
    expect((await api(`${a.path}/sharing`, { headers: bearer(stranger.accessToken) })).status).toBe(
      404,
    );
    expect(
      (
        await postJson(
          `${a.path}/positions`,
          { grantGeneration: 1, positions: [sample] },
          bearer(stranger.accessToken),
        )
      ).status,
    ).toBe(404);
    expect((await completed.ingest([sample])).status).toBe(404);
    expect((await completed.share({ action: "issue", delayS: 0, expiresInS: 100 })).status).toBe(
      404,
    );
    expect((await api(completed.path, { headers: completed.headers })).status).toBe(200);

    expect((await a.ingest([sample])).status).toBe(409);
    await a.issue();
    await b.issue();
    expect((await postJson(`${a.path}/positions`, { positions: [sample] }, a.headers)).status).toBe(
      400,
    );
    time.at(1);
    const first = { receipts: [{ sampleId: sample.sampleId, receivedAtMs: time.start + 1 }] };
    const duplicates = await Promise.all([a.ingest([sample, sample]), a.ingest([sample])]);
    for (const response of duplicates) {
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual(first);
    }
    time.at(100);
    expect(await (await a.ingest([sample])).json()).toEqual(first);
    expect((await a.ingest([later, { ...sample, lon: 0.5 }])).status).toBe(409);
    expect((await b.ingest([{ ...sample, lon: 0.5 }])).status).toBe(200);
    time.at(200);
    expect(await (await a.ingest([later])).json()).toEqual({
      receipts: [{ sampleId: later.sampleId, receivedAtMs: time.start + 200 }],
    });
  });

  it("projects backfill, explicit gaps and privacy crossings on every viewer surface and reconnect", async () => {
    const voyage = await setup();
    const other = await setup();
    const time = clock();
    const slug = await voyage.issue();
    const otherSlug = await other.issue();
    const ws = await connect(slug);
    expect(await ws.next()).toEqual(unavailable);
    const segment = crypto.randomUUID();
    const a = position(time.start + 100, -0.02, segment);
    const b = position(time.start + 200, 0.02, segment);
    // The recorder marks gapBefore by giving the next fix a different persisted segment UUID.
    const afterGap = position(time.start + 300, 0.021);
    const afterHidden = position(time.start + 500, 0.022, afterGap.segmentId);
    const hidden = position(time.start + 400, 0, afterGap.segmentId);
    const future = position(time.start + 1000, 0.022, afterGap.segmentId);
    await env.DB.prepare("INSERT INTO privacy_zones VALUES (?, ?, ?, ?, ?)")
      .bind(crypto.randomUUID(), voyage.userId, 0, 0, 100)
      .run();

    time.at(600);
    expect((await voyage.ingest([b, future, afterGap, a, b, afterHidden, hidden])).status).toBe(
      200,
    );
    const expected = {
      status: "available",
      current: viewerFix(afterHidden),
      segments: [[a], [b], [afterGap], [afterHidden]].map((points) => points.map(viewerFix)),
    };
    expect(await ws.next()).toEqual(expected);
    expect(await snapshot(slug)).toEqual(expected);
    expect(await snapshot(otherSlug)).toEqual(unavailable);
    expect(await (await voyage.state()).json()).toEqual({
      sharing: "on",
      grantGeneration: 1,
      delayS: 0,
      preview: expected,
    });
    await evictDurableObject(voyage.stub);

    time.at(1200);
    const retried = await voyage.ingest([future]);
    expect(await retried.json()).toEqual({
      receipts: [{ sampleId: future.sampleId, receivedAtMs: time.start + 600 }],
    });
    expect(await ws.next()).toEqual(expected);
    const reconnected = await connect(slug);
    expect(await reconnected.next()).toEqual(expected);
    const page = await exports.default.fetch(`https://madegood.test/v/${slug}`);
    const html = await page.text();
    expect(page.headers.get("Cache-Control")).toBe("private, no-store");
    expect(page.headers.get("Referrer-Policy")).toBe("no-referrer");
    expect(html).toContain('property="og:title" content="MadeGood voyage position"');
    expect(html).not.toMatch(/Synthetic Private|0\.022|sampleId|segmentId|slugHash|receivedAtMs/);
    expect(html).not.toContain(slug);

    // Privacy edits take effect on active connections, even when no new fix arrives.
    await env.DB.prepare("INSERT INTO privacy_zones VALUES (?, ?, ?, ?, ?)")
      .bind(crypto.randomUUID(), voyage.userId, 0, afterHidden.lon, 100)
      .run();
    time.at(6200);
    expect(await runDurableObjectAlarm(voyage.stub)).toBe(true);
    expect(await ws.next()).toEqual(unavailable);
    expect(await reconnected.next()).toEqual(unavailable);
    expect(await snapshot(slug)).toEqual(unavailable);
  });

  it("alarms release delayed fixes, clear stale state and close at exclusive expiry without new input", async () => {
    const voyage = await setup();
    const time = clock();
    const slug = await voyage.issue(10, 700);
    const ws = await connect(slug);
    expect(await ws.next()).toEqual(unavailable);
    time.at(8000);
    const fix = position(time.start + 100, 2);
    expect((await voyage.ingest([fix])).status).toBe(200);
    expect(await ws.next()).toEqual(unavailable);
    expect(await alarmAt(voyage.stub)).toBe(time.start + 10_100);
    time.at(10_099);
    expect(await snapshot(slug)).toEqual(unavailable);
    time.at(10_100);
    expect(await runDurableObjectAlarm(voyage.stub)).toBe(true);
    expect(await ws.next()).toEqual({
      status: "available",
      current: viewerFix(fix),
      segments: [[viewerFix(fix)]],
    });

    expect((await voyage.share({ action: "delay", delayS: 11 })).status).toBe(200);
    expect(await ws.next()).toEqual(unavailable);
    expect((await voyage.share({ action: "delay", delayS: 10 })).status).toBe(200);
    expect(await ws.next()).toMatchObject({ status: "available" });

    time.at(608_000);
    await runDurableObjectAlarm(voyage.stub);
    expect(await ws.next()).toMatchObject({ status: "available" });
    expect(await alarmAt(voyage.stub)).toBe(time.start + 610_100);
    time.at(610_100);
    await runDurableObjectAlarm(voyage.stub);
    expect(await ws.next()).toEqual(unavailable);
    time.at(698_000);
    await runDurableObjectAlarm(voyage.stub);
    expect(await ws.next()).toEqual(unavailable);
    expect(await alarmAt(voyage.stub)).toBe(time.start + 700_000);
    time.at(700_000);
    expect(await runDurableObjectAlarm(voyage.stub)).toBe(true);
    expect(await ws.next()).toEqual(unavailable);
    expect(await ws.closed).toBe(1008);
    expect(await snapshot(slug)).toEqual(unavailable);
    expect((await api(shareURL(slug), { headers: { Upgrade: "websocket" } })).status).toBe(200);
    expect((await voyage.ingest([fix])).status).toBe(409);
    const freshSlug = await voyage.issue();
    expect(freshSlug).not.toBe(slug);
    expect(await snapshot(freshSlug)).toEqual(unavailable);
    expect(await snapshot(slug)).toEqual(unavailable);
  });

  it("clears the remaining viewers when another viewer disconnects at expiry", async () => {
    const voyage = await setup();
    const time = clock();
    const slug = await voyage.issue(0, 10);
    const first = await connect(slug);
    const remaining = await connect(slug);
    expect(await first.next()).toEqual(unavailable);
    expect(await remaining.next()).toEqual(unavailable);
    time.at(100);
    expect((await voyage.ingest([position(time.start + 100, 1)])).status).toBe(200);
    expect(await first.next()).toMatchObject({ status: "available" });
    expect(await remaining.next()).toMatchObject({ status: "available" });

    time.at(10_000);
    first.ws.close(1000);
    expect(await remaining.next()).toEqual(unavailable);
    expect(await remaining.closed).toBe(1008);
    expect(await alarmAt(voyage.stub)).toBeNull();
  });

  it("preserves a legacy issuance-millisecond receipt in a mixed retry", async () => {
    const voyage = await setup();
    const time = clock();
    const slug = await voyage.issue();
    const legacy = position(time.start, 1);
    await runInDurableObject(voyage.stub, (_, state) => {
      state.storage.sql.exec(
        "INSERT INTO positions VALUES (?, ?, ?, ?, ?, ?, 1)",
        legacy.sampleId,
        legacy.segmentId,
        legacy.capturedAtMs,
        legacy.lat,
        legacy.lon,
        time.start,
      );
    });
    time.at(10);
    const fresh = position(time.start + 10, 2);
    expect(await (await voyage.ingest([legacy, fresh])).json()).toEqual({
      receipts: [
        { sampleId: legacy.sampleId, receivedAtMs: time.start },
        { sampleId: fresh.sampleId, receivedAtMs: time.start + 10 },
      ],
    });
    expect((await voyage.ingest([position(time.start, 3)])).status).toBe(409);
    expect(await snapshot(slug)).toEqual({
      status: "available",
      current: viewerFix(fresh),
      segments: [[viewerFix(fresh)]],
    });
  });

  it("releases old positions when rotating a full share", async () => {
    const voyage = await setup();
    const time = clock();
    const oldSlug = await voyage.issue();
    time.at(1);
    await runInDurableObject(voyage.stub, (_, state) => {
      state.storage.sql.exec(
        `WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM rows WHERE n < 10000)
         INSERT INTO positions SELECT 'synthetic-' || n, 'synthetic', ?, 0, 1, ?, 1 FROM rows`,
        time.start + 1,
        time.start + 1,
      );
    });
    expect(await (await voyage.ingest([position(time.start + 1, 2)])).json()).toEqual({
      error: "live_capacity",
    });
    const rotated = await voyage.share({ action: "rotate", delayS: 0, expiresInS: 60 });
    expect(rotated.status).toBe(200);
    const { slug, grantGeneration } = await rotated.json<{
      slug: string;
      grantGeneration: number;
    }>();
    time.at(2);
    const fix = position(time.start + 2, 3);
    expect((await voyage.ingest([fix], 1)).status).toBe(409);
    expect((await voyage.ingest([fix], grantGeneration)).status).toBe(200);
    expect(await snapshot(oldSlug)).toEqual(unavailable);
    expect(await snapshot(slug)).toMatchObject({ current: viewerFix(fix) });
  });

  it.each(["pause", "rotate", "revoke", "delete"] as const)(
    "revalidates a suspended broadcast after %s before sending",
    async (action) => {
      const voyage = await setup();
      const time = clock();
      const slug = await voyage.issue();
      const ws = await connect(slug);
      expect(await ws.next()).toEqual(unavailable);
      time.at(100);
      expect((await voyage.ingest([position(time.start + 100, 1)])).status).toBe(200);
      expect(await ws.next()).toMatchObject({ status: "available" });
      const key = { userId: voyage.userId, voyageId: voyage.voyageId };
      const rotatedSlug = await runInDurableObject(voyage.stub, async (instance) => {
        // Both tasks run in the same DO context. Hold the older broadcast after its D1 read.
        const entered = deferred<void>();
        const release = deferred<void>();
        type AccessReader = { readAccess(identity: typeof key): Promise<unknown> };
        const target = instance as unknown as AccessReader;
        const original = target.readAccess.bind(target);
        const spy = vi.spyOn(target, "readAccess").mockImplementationOnce(async (identity) => {
          const result = await original(identity);
          entered.resolve();
          await release.promise;
          return result;
        });
        const pending = instance.alarm();
        await entered.promise;
        try {
          if (action === "delete") {
            const removed = await createApp().request(
              "/api/me",
              { method: "DELETE", headers: voyage.headers },
              env,
            );
            expect(removed.status).toBe(204);
            return null;
          }
          const result = await instance.configure(
            key,
            action === "rotate" ? { action, delayS: 0, expiresInS: 1200 } : { action },
          );
          expect(result.status).toBe("ok");
          if (result.status !== "ok") return null;
          return (await result.response.json<{ slug?: string }>()).slug ?? null;
        } finally {
          release.resolve();
          await pending;
          spy.mockRestore();
        }
      });
      expect(await ws.next()).toEqual(unavailable);
      expect(await snapshot(slug)).toEqual(unavailable);
      if (action !== "pause") expect(await ws.closed).toBe(1008);
      if (action === "rotate") {
        expect(rotatedSlug).toBeTruthy();
        if (!rotatedSlug) throw new Error("Rotation did not issue a link");
        expect(rotatedSlug).not.toBe(slug);
        expect(await snapshot(rotatedSlug)).toEqual(unavailable);
        expect(await (await connect(rotatedSlug)).next()).toEqual(unavailable);
      }
      if (action === "delete") {
        expect((await voyage.state()).status).toBe(401);
        expect((await voyage.ingest([position(time.start + 100, 3)])).status).toBe(401);
        expect((await voyage.remove()).status).toBe(204);
        await runInDurableObject(voyage.stub, (_, state) => {
          expect(state.storage.sql.exec("SELECT * FROM positions").toArray()).toEqual([]);
          expect(state.storage.sql.exec("SELECT * FROM live_settings").toArray()).toEqual([]);
        });
      }
      if (action === "pause") {
        expect(await ws.next()).toEqual(unavailable);
        expect(await (await connect(slug)).next()).toEqual(unavailable);
        expect((await voyage.share({ action: "resume" })).status).toBe(200);
        expect(await ws.next()).toMatchObject({ status: "available" });
      }
      expect(ws.messages.slice(2, action === "pause" ? 4 : undefined)).toEqual(
        action === "pause" ? [unavailable, unavailable] : [unavailable],
      );
    },
  );
});

it("fences an earlier upload when a second controller revokes and reissues", async () => {
  const voyage = await setup();
  const time = clock();
  const oldSlug = await voyage.issue();
  const { grantGeneration } = await (await voyage.state()).json<{ grantGeneration: number }>();
  const oldViewer = await connect(oldSlug);
  expect(await oldViewer.next()).toEqual(unavailable);
  // Both times are ahead of issuance of the replacement. Timing alone cannot
  // authorize this batch for the replacement.
  const oldFix = position(time.start + 550, 1);
  time.at(400);
  const alreadyAccepted = position(time.start + 100, 2);
  expect((await voyage.ingest([alreadyAccepted])).status).toBe(200);
  expect(await oldViewer.next()).toMatchObject({ status: "available" });

  const freshSlug = await runInDurableObject(voyage.stub, async (instance, state) => {
    const entered = deferred<void>();
    const release = deferred<void>();
    const key = { userId: voyage.userId, voyageId: voyage.voyageId };
    type Registrar = { register(identity: typeof key): Promise<boolean> };
    const target = instance as unknown as Registrar;
    const original = target.register.bind(target);
    const spy = vi.spyOn(target, "register").mockImplementationOnce(async (identity) => {
      const registered = await original(identity);
      entered.resolve();
      await release.promise;
      return registered;
    });
    const pending = instance.ingest(key, grantGeneration, [oldFix]);
    await entered.promise;
    try {
      time.at(500);
      expect((await instance.configure(key, { action: "revoke" })).status).toBe("ok");
      const issued = await instance.configure(key, { action: "issue", delayS: 0, expiresInS: 60 });
      if (issued.status !== "ok") throw new Error("Unable to issue replacement grant");
      const grant = await issued.response.json<{ slug: string; grantGeneration: number }>();
      expect(grant.grantGeneration).toBe(grantGeneration + 1);
      time.at(600);
      release.resolve();
      expect(await pending).toEqual({ status: "stale_grant" });
      expect(state.storage.sql.exec("SELECT sampleId FROM positions").toArray()).toEqual([]);
      return grant.slug;
    } finally {
      release.resolve();
      await pending;
      spy.mockRestore();
    }
  });
  expect(await oldViewer.next()).toEqual(unavailable);
  expect(await oldViewer.closed).toBe(1008);
  expect(await snapshot(freshSlug)).toEqual(unavailable);
  const stale = await voyage.ingest([alreadyAccepted], grantGeneration);
  expect(stale.status).toBe(409);
  expect(await stale.json()).toEqual({ error: "stale_grant" });
  expect((await voyage.ingest([alreadyAccepted], grantGeneration + 1)).status).toBe(409);
  const freshFix = position(time.start + 550, 3);
  expect((await voyage.ingest([freshFix], grantGeneration + 1)).status).toBe(200);
  expect(await snapshot(freshSlug)).toEqual({
    status: "available",
    current: viewerFix(freshFix),
    segments: [[viewerFix(freshFix)]],
  });
});

it("blocks an in-flight first batch after account deletion has purged its registered object", async () => {
  const voyage = await setup();
  const result = await runInDurableObject(voyage.stub, async (instance) => {
    const entered = deferred<void>();
    const release = deferred<void>();
    type Registrar = { register(key: { userId: string; voyageId: string }): Promise<boolean> };
    const target = instance as unknown as Registrar;
    const original = target.register.bind(target);
    const spy = vi.spyOn(target, "register").mockImplementationOnce(async (key) => {
      const result = await original(key);
      entered.resolve();
      await release.promise;
      return result;
    });
    const key = { userId: voyage.userId, voyageId: voyage.voyageId };
    const pending = instance.ingest(key, 1, [position(Date.now(), 1)]);
    await entered.promise;
    try {
      const removed = await createApp().request(
        "/api/me",
        { method: "DELETE", headers: voyage.headers },
        env,
      );
      expect(removed.status).toBe(204);
    } finally {
      release.resolve();
      spy.mockRestore();
    }
    return await pending;
  });
  expect(result).toEqual({ status: "unauthorized" });
  expect(
    await env.DB.prepare("SELECT 1 FROM voyage_live_registry WHERE user_id = ?")
      .bind(voyage.userId)
      .first(),
  ).toBeNull();
  await runInDurableObject(voyage.stub, (_, state) => {
    expect(state.storage.sql.exec("SELECT * FROM positions").toArray()).toEqual([]);
  });
});

it("fails closed when authoritative privacy cannot be loaded and refreshes when read access recovers", async () => {
  const voyage = await setup();
  const time = clock();
  const slug = await voyage.issue();
  time.at(100);
  const fix = position(time.start + 100, 1);
  expect((await voyage.ingest([fix])).status).toBe(200);
  const ws = await connect(slug);
  expect(await ws.next()).toMatchObject({ status: "available" });
  await runInDurableObject(voyage.stub, async (instance) => {
    type AccessReader = { readAccess(key: { userId: string; voyageId: string }): Promise<unknown> };
    const spy = vi
      .spyOn(instance as unknown as AccessReader, "readAccess")
      .mockRejectedValueOnce(new Error("Synthetic D1 failure"));
    try {
      await instance.alarm();
    } finally {
      spy.mockRestore();
    }
  });
  expect(await ws.next()).toEqual(unavailable);
  await runDurableObjectAlarm(voyage.stub);
  expect(await ws.next()).toEqual({
    status: "available",
    current: viewerFix(fix),
    segments: [[viewerFix(fix)]],
  });
});

it("captures first receipt before asynchronous ownership and persistence work", async () => {
  const voyage = await setup();
  const time = clock();
  const slug = await voyage.issue();
  time.at(100);
  const fix = position(time.start + 200, 1);
  const key = { userId: voyage.userId, voyageId: voyage.voyageId };
  const accepted = await runInDurableObject(voyage.stub, async (instance) => {
    type AccessReader = { readAccess(identity: typeof key): Promise<unknown> };
    const target = instance as unknown as AccessReader;
    const original = target.readAccess.bind(target);
    const spy = vi.spyOn(target, "readAccess").mockImplementationOnce(async (identity) => {
      const access = await original(identity);
      time.at(300);
      return access;
    });
    try {
      return await instance.ingest(key, 1, [fix]);
    } finally {
      spy.mockRestore();
    }
  });
  const receipts = [{ sampleId: fix.sampleId, receivedAtMs: time.start + 100 }];
  expect(accepted).toEqual({ status: "ok", receipts });
  expect(await (await voyage.ingest([fix])).json()).toEqual({ receipts });
  expect(await snapshot(slug)).toEqual(unavailable);
});
