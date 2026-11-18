import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/server/app";
import { userPrefix } from "../src/server/lib/storage";
import { api, bearer, identityToken, postJson, signIn } from "./apple";

const voyage = {
  title: "Synthetic cruise",
  startedAt: "2026-01-02T00:00:00.000Z",
};
const leg = {
  fromName: "Departure",
  toName: "Arrival",
  startedAt: voyage.startedAt,
  endedAt: "2026-01-12T12:00:00.000Z",
  distanceM: 150_000,
};

const voyagePath = (id: string) => `/voyages/${id}`;
const legPath = (voyageId: string, legId: string) => `${voyagePath(voyageId)}/legs/${legId}`;
const putJson = (body: unknown, token?: string): RequestInit => ({
  method: "PUT",
  headers: { ...(token ? bearer(token) : {}), "content-type": "application/json" },
  body: JSON.stringify(body),
});
async function trackBytes(id: string, latitude = 0.001, startedAt = leg.startedAt) {
  return gzipJSON({
    v: 1,
    sessionId: id,
    startedAt,
    sport: "sailing",
    gps: { t: [0], lat: [latitude], lon: [0.002], spd: [2], crs: [90], hacc: [4] },
    hr: { t: [], bpm: [] },
    events: [],
  });
}
async function gzipJSON(value: unknown) {
  return gzipText(JSON.stringify(value));
}
async function gzipText(text: string) {
  const gzip = new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(gzip).arrayBuffer());
}
const putTrack = (bytes: Uint8Array, token: string): RequestInit => ({
  method: "PUT",
  headers: { ...bearer(token), "content-type": "application/gzip" },
  body: new Uint8Array(bytes),
});
const deleteAccount = (token: string) => api("/me", { method: "DELETE", headers: bearer(token) });

async function createLeg(
  token: string,
  voyageId = crypto.randomUUID(),
  legId = crypto.randomUUID(),
) {
  expect((await api(voyagePath(voyageId), putJson(voyage, token))).status).toBe(201);
  expect((await api(legPath(voyageId, legId), putJson(leg, token))).status).toBe(201);
  return { voyageId, legId, trackPath: `${legPath(voyageId, legId)}/track` };
}

describe("private voyage sync", () => {
  it("leaves the private voyage routes disabled without the local binding", async () => {
    const owner = await signIn();
    const path = `/api${voyagePath(crypto.randomUUID())}`;
    const localDisabled: Env = { ...env, VOYAGE_PRIVATE_LOCAL: undefined };
    const app = createApp();
    for (const [url, request] of [
      ["/api/voyages", { headers: bearer(owner.accessToken) }],
      [path, putJson(voyage, owner.accessToken)],
    ] as const) {
      const response = await app.request(url, request, localDisabled);
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
    }
  });

  it("scopes reads, writes and parent relationships to the authenticated account", async () => {
    const owner = await signIn();
    const other = await signIn();
    expect(
      (
        await api("/me", {
          ...putJson({ defaultVisibility: "public" }, owner.accessToken),
          method: "PATCH",
        })
      ).status,
    ).toBe(200);
    const { voyageId, legId, trackPath } = await createLeg(owner.accessToken);
    const parent = voyagePath(voyageId);
    const child = legPath(voyageId, legId);
    const bytes = await trackBytes(legId);
    expect((await api(trackPath, putTrack(bytes, owner.accessToken))).status).toBe(204);
    expect((await api("/voyages")).status).toBe(401);
    expect((await api(child)).status).toBe(401);
    expect((await api(trackPath)).status).toBe(401);
    expect((await api(child, putJson(leg))).status).toBe(401);

    const headers = bearer(other.accessToken);
    expect(await (await api("/voyages", { headers })).json()).toEqual({
      voyages: [],
      nextCursor: null,
    });
    for (const path of [parent, `${parent}/legs`, child, trackPath]) {
      const response = await api(path, { headers });
      expect(response.status, path).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
      expect(response.headers.get("cache-control")).toBe("private, no-store");
    }
    for (const [path, init] of [
      [child, putJson(leg, other.accessToken)],
      [trackPath, putTrack(bytes, other.accessToken)],
    ] as const) {
      const response = await api(path, init);
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found" });
    }
    await expect(
      env.DB.prepare(
        "insert into legs (user_id, id, voyage_id, started_at, ended_at) values (?, ?, ?, 0, 1)",
      )
        .bind(other.user.id, crypto.randomUUID(), voyageId)
        .run(),
    ).rejects.toThrow(/FOREIGN KEY/);

    // IDs are opaque outside their account. Collisions only create records for the caller.
    await createLeg(other.accessToken, voyageId, legId);
    expect((await api(trackPath, { headers })).status).toBe(404);
    expect(
      (await api(trackPath, putTrack(await trackBytes(legId, 0.005), other.accessToken))).status,
    ).toBe(204);
    const originalTrack = await api(trackPath, { headers: bearer(owner.accessToken) });
    expect(new Uint8Array(await originalTrack.arrayBuffer())).toEqual(bytes);
  });

  it("normalizes identical metadata retries, detects conflicts and prevents reparenting", async () => {
    const { accessToken } = await signIn();
    const headers = bearer(accessToken);
    const id = crypto.randomUUID();
    const path = voyagePath(id);
    const creates = await Promise.all([
      api(voyagePath(id.toUpperCase()), putJson(voyage, accessToken)),
      api(
        path,
        putJson(
          {
            ...voyage,
            title: ` ${voyage.title} `,
            startedAt: "2026-01-01T23:00:00-01:00",
            boatName: null,
            endedAt: null,
          },
          accessToken,
        ),
      ),
    ]);
    expect(creates.map((r) => r.status).sort()).toEqual([200, 201]);
    const stored = await (await api(path, { headers })).json();
    expect(stored).toEqual({ id, ...voyage, boatName: null, endedAt: null });
    const conflict = await api(path, putJson({ ...voyage, title: "Different title" }, accessToken));
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ error: "sync_conflict" });

    const legId = crypto.randomUUID();
    const child = legPath(id, legId);
    const firstLegs = await Promise.all([
      api(child, putJson(leg, accessToken)),
      api(child, putJson({ ...leg, distanceM: 1 }, accessToken)),
    ]);
    expect(firstLegs.map((r) => r.status).sort()).toEqual([201, 409]);
    const winningLeg = firstLegs[0].status === 201 ? leg : { ...leg, distanceM: 1 };
    const retry = await api(legPath(id, legId.toUpperCase()), putJson(winningLeg, accessToken));
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual({ id: legId, voyageId: id, ...winningLeg });

    const secondId = crypto.randomUUID();
    expect((await api(voyagePath(secondId), putJson(voyage, accessToken))).status).toBe(201);
    expect((await api(legPath(secondId, legId), putJson(winningLeg, accessToken))).status).toBe(
      409,
    );
    expect((await api(legPath(secondId, legId), { headers })).status).toBe(404);
    expect(await (await api(`${path}/legs`, { headers })).json()).toEqual({
      legs: [{ id: legId, voyageId: id, ...winningLeg }],
      nextCursor: null,
    });
    expect(await (await api(`${path}/legs?cursor=${legId}`, { headers })).json()).toEqual({
      legs: [],
      nextCursor: null,
    });
    const voyages = (await (await api("/voyages", { headers })).json()) as {
      voyages: { id: string }[];
    };
    expect(voyages.voyages.map((row) => row.id)).toEqual([id, secondId].sort());
    expect(await (await api(path, { headers })).json()).toEqual(stored);
  });

  it("rejects invalid metadata and sharing fields", async () => {
    const { accessToken } = await signIn();
    const { voyageId } = await createLeg(accessToken);
    const create = voyagePath(crypto.randomUUID());
    expect((await api("/voyages/not-a-uuid", putJson(voyage, accessToken))).status).toBe(400);
    for (const body of [
      { ...voyage, title: "  " },
      { ...voyage, startedAt: "tomorrow" },
      { ...voyage, endedAt: "2026-01-01T00:00:00Z" },
      { ...voyage, visibility: "public" },
      { ...voyage, userId: "other-account" },
    ]) {
      expect((await api(create, putJson(body, accessToken))).status).toBe(400);
    }
    const path = legPath(voyageId, crypto.randomUUID());
    expect((await api(path, putJson({ ...leg, distanceM: -1 }, accessToken))).status).toBe(400);
    expect((await api(path, putJson({ ...leg, endedAt: null }, accessToken))).status).toBe(400);
    expect(
      (await api(create, putJson({ ...voyage, title: "x".repeat(9000) }, accessToken))).status,
    ).toBe(413);
  });

  it("rejects malformed or foreign tracks before the immutable slot is used", async () => {
    const { accessToken } = await signIn();
    const { legId, trackPath } = await createLeg(accessToken);
    const malformed = await gzipJSON({ v: 1, sessionId: legId });
    const foreign = await trackBytes(crypto.randomUUID());
    const brokenColumn = await gzipJSON({
      v: 1,
      sessionId: legId,
      sport: "sailing",
      startedAt: leg.startedAt,
      gps: { t: [0], lat: [], lon: [0], spd: [null], crs: [null], hacc: [5] },
      hr: { t: [], bpm: [] },
      events: [],
    });
    const overflowing = await gzipText(
      JSON.stringify({
        v: 1,
        sessionId: legId,
        sport: "sailing",
        startedAt: leg.startedAt,
        gps: { t: [], lat: [], lon: [], spd: [], crs: [], hacc: [] },
        hr: { t: [], bpm: [] },
        events: [{ t: 0, type: "mark", data: { nested: ["synthetic-overflow"] } }],
      }).replace('"synthetic-overflow"', "1e400"),
    );
    for (const bytes of [malformed, foreign, brokenColumn, overflowing]) {
      const result = await api(trackPath, putTrack(bytes, accessToken));
      expect(result.status).toBe(400);
      expect(await result.json()).toMatchObject({ error: "invalid_track" });
    }
    expect((await api(trackPath, { headers: bearer(accessToken) })).status).toBe(404);
    expect((await api(trackPath, putTrack(await trackBytes(legId), accessToken))).status).toBe(204);
  });

  it("stores exact gzip bytes once and refuses a competing upload", async () => {
    const { accessToken, user } = await signIn();
    const { legId, trackPath } = await createLeg(accessToken);
    const headers = bearer(accessToken);
    expect((await api(trackPath, { headers })).status).toBe(404);
    const bytes = await trackBytes(legId);
    const competingBytes = await trackBytes(legId, 0.003);
    const [first, second] = await Promise.all([
      api(trackPath, putTrack(bytes, accessToken)),
      api(trackPath, putTrack(competingBytes, accessToken)),
    ]);
    expect([first.status, second.status].sort()).toEqual([204, 409]);
    const original = first.status === 204 ? bytes : competingBytes;
    const winner = first.status === 204 ? first : second;
    const {
      objects: [stored],
    } = await env.TRACKS.list({ prefix: userPrefix(user.id) });
    expect(stored?.uploaded).toBeInstanceOf(Date);
    expect(stored?.httpEtag).toBe(winner.headers.get("etag"));
    const retry = await api(trackPath, putTrack(original, accessToken));
    expect(retry.status).toBe(204);
    expect(retry.headers.get("etag")).toBe(winner.headers.get("etag"));
    const {
      objects: [retried],
    } = await env.TRACKS.list({ prefix: userPrefix(user.id) });
    expect(retried?.uploaded).toEqual(stored?.uploaded);
    const download = await api(trackPath, { headers });
    expect(download.status).toBe(200);
    expect(download.headers.get("cache-control")).toBe("private, no-store");
    expect(download.headers.get("content-type")).toBe("application/gzip");
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(original);
    expect((await api(trackPath, putTrack(new Uint8Array([1, 2, 3]), accessToken))).status).toBe(
      400,
    );
    expect((await api(trackPath, { method: "PUT", headers, body: "{}" })).status).toBe(415);
  });

  it("keeps each leg's capture time and track separate", async () => {
    const { accessToken } = await signIn();
    const first = await createLeg(accessToken);
    const secondId = crypto.randomUUID();
    const secondPath = legPath(first.voyageId, secondId);
    const secondLeg = {
      ...leg,
      startedAt: "2026-01-14T00:00:00.000Z",
      endedAt: "2026-01-16T00:00:00.000Z",
    };
    expect((await api(secondPath, putJson(secondLeg, accessToken))).status).toBe(201);
    const firstBytes = await trackBytes(first.legId);
    const secondBytes = await trackBytes(secondId, 0.004, secondLeg.startedAt);
    expect((await api(first.trackPath, putTrack(firstBytes, accessToken))).status).toBe(204);
    expect((await api(`${secondPath}/track`, putTrack(secondBytes, accessToken))).status).toBe(204);
    expect((await api(secondPath, putJson(secondLeg, accessToken))).status).toBe(200);

    const headers = bearer(accessToken);
    expect(await (await api(secondPath, { headers })).json()).toMatchObject(secondLeg);
    const firstTrack = await api(first.trackPath, { headers });
    const secondTrack = await api(`${secondPath}/track`, { headers });
    expect(new Uint8Array(await firstTrack.arrayBuffer())).toEqual(firstBytes);
    expect(new Uint8Array(await secondTrack.arrayBuffer())).toEqual(secondBytes);
  });

  it("cascades account deletion and isolates storage even when the same Apple subject signs in again", async () => {
    const token = await identityToken();
    const owner = await signIn({ identityToken: token });
    const other = await signIn();
    const { voyageId, legId, trackPath } = await createLeg(owner.accessToken);
    await createLeg(other.accessToken, voyageId, legId);
    const bytes = await trackBytes(legId);
    expect((await api(trackPath, putTrack(bytes, owner.accessToken))).status).toBe(204);
    expect((await api(trackPath, putTrack(bytes, other.accessToken))).status).toBe(204);

    expect((await deleteAccount(owner.accessToken)).status).toBe(204);
    expect((await deleteAccount(owner.accessToken)).status).toBe(204);
    for (const table of ["voyages", "legs"]) {
      const row = await env.DB.prepare(`select id from ${table} where user_id = ?`)
        .bind(owner.user.id)
        .first();
      expect(row).toBeNull();
    }
    expect((await env.TRACKS.list({ prefix: userPrefix(owner.user.id) })).objects).toEqual([]);
    expect((await env.TRACKS.list({ prefix: userPrefix(other.user.id) })).objects).toHaveLength(1);
    expect((await api(trackPath, { headers: bearer(other.accessToken) })).status).toBe(200);
    expect((await api("/voyages", { headers: bearer(owner.accessToken) })).status).toBe(401);
    expect((await api(voyagePath(voyageId), putJson(voyage, owner.accessToken))).status).toBe(401);
    expect((await api(legPath(voyageId, legId), putJson(leg, owner.accessToken))).status).toBe(401);
    expect((await api(trackPath, putTrack(bytes, owner.accessToken))).status).toBe(401);
    expect((await postJson("/auth/refresh", { refreshToken: owner.refreshToken })).status).toBe(
      401,
    );

    const returning = await signIn({ identityToken: token });
    expect(returning.user.id).not.toBe(owner.user.id);
    expect(
      await (await api("/voyages", { headers: bearer(returning.accessToken) })).json(),
    ).toEqual({ voyages: [], nextCursor: null });
  });

  it("rejects a metadata insert after the account disappears between auth and the write", async () => {
    const { accessToken, user } = await signIn();
    const db = new Proxy(env.DB, {
      get(target, property) {
        if (property === "batch") {
          return async (statements: D1PreparedStatement[]) => {
            expect((await deleteAccount(accessToken)).status).toBe(204);
            return target.batch(statements);
          };
        }
        const value = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const response = await createApp().request(
      `/api${voyagePath(crypto.randomUUID())}`,
      putJson(voyage, accessToken),
      { ...env, DB: db },
    );
    expect(response.status).toBe(401);
    expect(
      await env.DB.prepare("select id from voyages where user_id = ?").bind(user.id).first(),
    ).toBeNull();
  });

  it.each([false, true])(
    "removes a late track after account deletion, lookup failure %s",
    async (failLookup) => {
      const { accessToken, user } = await signIn();
      const { legId, trackPath } = await createLeg(accessToken);
      let latePut = false;
      let lookupFailed = false;
      const bucket = new Proxy(env.TRACKS, {
        get(target, property) {
          if (property === "put") {
            return async (key: string, bytes: Uint8Array, options: R2PutOptions) => {
              expect((await deleteAccount(accessToken)).status).toBe(204);
              const stored = await target.put(key, bytes, options);
              latePut = stored !== null;
              return stored;
            };
          }
          const value = Reflect.get(target, property);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      const db = new Proxy(env.DB, {
        get(target, property) {
          if (property === "prepare") {
            return (statement: string) => {
              if (failLookup && latePut && !lookupFailed) {
                lookupFailed = true;
                throw new Error("Synthetic ownership read failure");
              }
              return target.prepare(statement);
            };
          }
          const value = Reflect.get(target, property);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      const response = await createApp().request(
        `/api${trackPath}`,
        putTrack(await trackBytes(legId), accessToken),
        { ...env, DB: db, TRACKS: bucket },
      );
      expect(latePut).toBe(true);
      expect(lookupFailed).toBe(failLookup);
      expect(response.status).toBe(404);
      expect((await env.TRACKS.list({ prefix: userPrefix(user.id) })).objects).toEqual([]);
    },
  );
});
