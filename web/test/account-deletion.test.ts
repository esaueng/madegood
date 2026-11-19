import { env } from "cloudflare:workers";
import { drizzle } from "drizzle-orm/d1";
import { describe, expect, it, vi } from "vitest";
import { AccountDeleting } from "../src/server/auth/account-state";
import { consumeRefreshToken, issueTokenPair } from "../src/server/auth/tokens";
import {
  DELETION_ALERT_ATTEMPTS,
  DELETION_GRACE_MS,
  requestAccountDeletion,
  runAccountDeletion,
  sweepAccountDeletions,
} from "../src/server/lib/account-deletion";
import { createExportJob, firstMessage, runExportStep } from "../src/server/lib/export-job";
import { processMessage } from "../src/server/lib/postprocess";
import {
  CLAIM_LEASE_MS,
  claimAndDelete,
  collectR2Garbage,
  UPLOAD_GRACE_MS,
} from "../src/server/lib/r2-garbage";
import {
  AfterCommit,
  discardUpload,
  insertSession,
  replaceSessionMetadata,
  storeTrack,
} from "../src/server/lib/session-upload";
import { userPrefix } from "../src/server/lib/storage";
import { trackKey } from "../src/server/lib/track";
import { liveVoyage } from "../src/server/live/registry";
import { api, deleteMe, identityToken, postJson, signIn } from "./apple";

// Forced interleavings from the scoped re-check of #78. Synthetic data only (AGENTS.md).

const START_MS = 946720800000;
const db = () => drizzle(env.DB);
const fields = {
  sport: "kayak" as const,
  startedAt: START_MS,
  endedAt: null,
  durationS: 3600,
  movingS: 3300,
  distanceM: 5000,
  maxSpeedMps: 2.4,
  avgSpeedMps: 1.52,
  summaryJson: null,
  analyzerVersion: "1.0.0",
};

const sql = (query: string, ...values: unknown[]) =>
  env.DB.prepare(query)
    .bind(...values)
    .run();
const one = <T>(query: string, ...values: unknown[]) =>
  env.DB.prepare(query)
    .bind(...values)
    .first<T>();
const pending = async (userId: string) =>
  (
    await env.DB.prepare("select key from pending_r2_deletes where user_id = ? order by key")
      .bind(userId)
      .all<{ key: string }>()
  ).results.map((r) => r.key);

/** env.TRACKS whose `delete` fails while `fail(keys)` says so. */
function flakyBucket(fail: (keys: string[]) => boolean): R2Bucket {
  return new Proxy(env.TRACKS, {
    get(target, property) {
      if (property === "delete") {
        return async (keys: string | string[]) => {
          const list = Array.isArray(keys) ? keys : [keys];
          if (fail(list)) throw new Error("synthetic R2 failure");
          return target.delete(keys);
        };
      }
      const value = Reflect.get(target, property);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

async function sessionWithKey(userId: string, key: string, revision = 1) {
  const id = crypto.randomUUID();
  await env.TRACKS.put(key.replace("<id>", id), "track");
  await sql(
    "insert into sessions (id, user_id, sport, started_at, upload_revision, track_key) values (?, ?, 'sup', ?, ?, ?)",
    id,
    userId,
    START_MS,
    revision,
    key.replace("<id>", id),
  );
  return { id, key: key.replace("<id>", id) };
}

/** Lets every ledger claim lapse, as if a collector's lease ran out (claims are one-way). */
const lapseClaims = () =>
  env.DB.prepare(
    "update pending_r2_deletes set claimed_at = claimed_at - ? where claim is not null",
  )
    .bind(CLAIM_LEASE_MS + 1)
    .run();

describe("finding 1: no track key is lost to a concurrent detach", () => {
  it("records a detached out-of-prefix key in the batch, so deletion still finds it", async () => {
    const owner = await signIn();
    const legacy = await sessionWithKey(owner.user.id, "legacy/<id>.gz");
    // A newer revision detaches the track, but deleting the object fails right then.
    const result = await replaceSessionMetadata(
      db(),
      flakyBucket(() => true),
      { id: legacy.id, userId: owner.user.id, revision: 2, fields },
    );
    expect(result.kind).toBe("updated");
    const row = await one<{ k: string | null }>(
      "select track_key as k from sessions where id = ?",
      legacy.id,
    );
    expect(row?.k).toBeNull();
    expect(await env.TRACKS.head(legacy.key)).not.toBeNull();
    expect(await pending(owner.user.id)).toEqual([legacy.key]);

    // The deletion pass never sees the key in a row, but the ledger has it (claimed by the
    // failed delete, so taken over once that claim lapses).
    await lapseClaims();
    expect(await requestAccountDeletion(env.DB, owner.user.id)).toBe(true);
    await runAccountDeletion(env, owner.user.id);
    expect(await env.TRACKS.head(legacy.key)).toBeNull();
    expect(await pending(owner.user.id)).toEqual([]);
  });

  it("refuses a higher revision that arrives after the lock, keeping the key for the sweep", async () => {
    const owner = await signIn();
    const legacy = await sessionWithKey(owner.user.id, "legacy/<id>.gz");
    // The PUT read the row before the lock and writes after it.
    const result = await replaceSessionMetadata(
      db(),
      env.TRACKS,
      { id: legacy.id, userId: owner.user.id, revision: 2, fields },
      { afterRead: async () => void (await requestAccountDeletion(env.DB, owner.user.id)) },
    );
    expect(result.kind).toBe("missing");
    const row = await one<{ k: string | null }>(
      "select track_key as k from sessions where id = ?",
      legacy.id,
    );
    expect(row?.k).toBe(legacy.key);
    await runAccountDeletion(env, owner.user.id);
    expect(await env.TRACKS.head(legacy.key)).toBeNull();
  });
});

describe("finding 2: an upload's cleanup only ever deletes its own object", () => {
  it("keeps B's attached object when A's attach fails and A cleans up", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await sql(
      "insert into sessions (id, user_id, sport, started_at) values (?, ?, 'sup', ?)",
      id,
      owner.user.id,
      START_MS,
    );
    const keyA = trackKey(userPrefix(owner.user.id), id, 0);
    const keyB = trackKey(userPrefix(owner.user.id), id, 0);
    expect(keyA).not.toBe(keyB);
    const input = { id, userId: owner.user.id, revision: 0 };
    // A writes its object; B uploads and attaches; then A's D1 attach fails.
    await expect(
      storeTrack(
        db(),
        env.TRACKS,
        { ...input, key: keyA, bytes: new Uint8Array([1]) },
        {
          afterPut: async () => {
            const b = await storeTrack(db(), env.TRACKS, {
              ...input,
              key: keyB,
              bytes: new Uint8Array([2]),
            });
            expect(b.kind).toBe("attached");
            throw new Error("synthetic D1 failure");
          },
        },
      ),
    ).rejects.toThrow("synthetic D1 failure");
    // What the route does on a failure: discard its own key.
    await discardUpload(db(), env.TRACKS, keyA, owner.user.id);
    expect(await env.TRACKS.head(keyA)).toBeNull();
    expect(await env.TRACKS.head(keyB)).not.toBeNull();
    const row = await one<{ k: string }>("select track_key as k from sessions where id = ?", id);
    expect(row?.k).toBe(keyB);
    expect(await pending(owner.user.id)).toEqual([]);
  });

  it("collects an upload that never attached once no attach can still happen", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    // A worker that recorded and wrote its object, then died before attaching.
    await sql(
      "insert into pending_r2_deletes (key, user_id, created_at) values (?, ?, ?)",
      key,
      owner.user.id,
      Date.now(),
    );
    await env.TRACKS.put(key, "orphan");
    const before = Date.now() - UPLOAD_GRACE_MS;
    expect(await collectR2Garbage(db(), env.TRACKS, { userId: owner.user.id, before })).toBe(0);
    expect(await env.TRACKS.head(key)).not.toBeNull();
    const later = Date.now() + 1;
    expect(await collectR2Garbage(db(), env.TRACKS, { userId: owner.user.id, before: later })).toBe(
      1,
    );
    expect(await env.TRACKS.head(key)).toBeNull();
  });
});

describe("finding 3: no write authorized before the lock lands after it", () => {
  it("refuses a session insert, a track attach and refresh tokens for a locked account", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await requestAccountDeletion(env.DB, owner.user.id);
    expect(
      await insertSession(db(), { id, userId: owner.user.id, revision: 0, fields }),
    ).toBeNull();
    expect(await one("select id from sessions where id = ?", id)).toBeNull();

    // A session created before the lock; its upload writes the object after the lock.
    const other = await signIn();
    const sid = crypto.randomUUID();
    await insertSession(db(), { id: sid, userId: other.user.id, revision: 0, fields });
    const key = trackKey(userPrefix(other.user.id), sid, 0);
    const stored = await storeTrack(
      db(),
      env.TRACKS,
      { id: sid, userId: other.user.id, revision: 0, key, bytes: new Uint8Array([1]) },
      { afterPut: async () => void (await requestAccountDeletion(env.DB, other.user.id)) },
    );
    expect(stored.kind).toBe("detached");
    // Its key is recorded, so the deletion collects it.
    expect(await pending(other.user.id)).toEqual([key]);
    await runAccountDeletion(env, other.user.id);
    expect(await env.TRACKS.head(key)).toBeNull();
  });

  it("drops a post-processing message for a locked account without writing", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await insertSession(db(), { id, userId: owner.user.id, revision: 0, fields });
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    const stored = await storeTrack(db(), env.TRACKS, {
      id,
      userId: owner.user.id,
      revision: 0,
      key,
      bytes: new Uint8Array([0x1f, 0x8b]),
    });
    if (stored.kind !== "attached") throw new Error("not attached");
    await requestAccountDeletion(env.DB, owner.user.id);
    const outcome = await processMessage(env, {
      v: 1,
      sessionId: id,
      userId: owner.user.id,
      revision: 0,
      etag: stored.etag,
    });
    expect(outcome).toBe("skipped_stale");
    const row = await one<{ p: string | null }>(
      "select processed_etag as p from sessions where id = ?",
      id,
    );
    expect(row?.p).toBeNull();
  });

  it("stores no live positions for a locked account (checked inside the Durable Object)", async () => {
    const owner = await signIn();
    const voyageId = crypto.randomUUID();
    await sql(
      "insert into voyages (user_id, id, title, started_at) values (?, ?, 'Synthetic', ?)",
      owner.user.id,
      voyageId,
      START_MS,
    );
    await requestAccountDeletion(env.DB, owner.user.id);
    const key = { userId: owner.user.id, voyageId };
    const result = await liveVoyage(env, key).ingest(key, 1, [
      { sampleId: "s1", segmentId: "g1", capturedAtMs: Date.now(), lat: 0, lon: 0 },
    ]);
    expect(result.status).toBe("unauthorized");
    const registered = await one(
      "select voyage_id from voyage_live_registry where user_id = ?",
      owner.user.id,
    );
    expect(registered).toBeNull();
  });
});

describe("finding 4: deletions finish without a cron, and failing ones back off", () => {
  it("lets a sign-in finish an expired grace period and start a fresh account", async () => {
    const sub = `001234.${crypto.randomUUID().replaceAll("-", "")}.0001`;
    const first = await signIn({ identityToken: await identityToken({ sub }) });
    expect((await deleteMe(first.accessToken, { finish: false })).status).toBe(202);
    const locked = await postJson("/auth/apple", { identityToken: await identityToken({ sub }) });
    expect(locked.status).toBe(409);
    // As if the grace period had passed with no cron (previews have none).
    await sql(
      "update users set deleted_at = ? where id = ?",
      Date.now() - DELETION_GRACE_MS - 1000,
      first.user.id,
    );
    const again = await signIn({ identityToken: await identityToken({ sub }) });
    expect(again.user.id).not.toBe(first.user.id);
    expect(await one("select id from users where id = ?", first.user.id)).toBeNull();
  });

  it("backs off a failing deletion so the next one still runs, and reports it", async () => {
    const stuck = await signIn();
    const fine = await signIn();
    for (const user of [stuck, fine]) {
      await sessionWithKey(user.user.id, `${userPrefix(user.user.id)}sessions/<id>/track.v1.gz`);
    }
    const past = Date.now() - DELETION_GRACE_MS - 1000;
    for (const [user, at] of [
      [stuck, past - 1000],
      [fine, past],
    ] as const) {
      await requestAccountDeletion(env.DB, user.user.id, at);
    }
    const failing = {
      ...env,
      TRACKS: flakyBucket((keys) => keys.some((k) => k.includes(stuck.user.id))),
    };
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    // One job per run: the older, failing one first; then it backs off and the other runs.
    const now = Date.now();
    expect((await sweepAccountDeletions(failing, now, 1)).failed).toBe(1);
    expect((await sweepAccountDeletions(failing, now, 1)).done).toBe(1);
    expect(await one("select id from users where id = ?", fine.user.id)).toBeNull();
    const row = await one<{ attempts: number; next: number }>(
      "select deletion_attempts as attempts, deletion_next_at as next from users where id = ?",
      stuck.user.id,
    );
    expect(row?.attempts).toBe(1);
    expect(row?.next).toBeGreaterThan(now);
    // Keeps failing: reported as an event once it has failed many times.
    for (let i = 1; i < DELETION_ALERT_ATTEMPTS; i++) {
      await sql("update users set deletion_next_at = null where id = ?", stuck.user.id);
      await sweepAccountDeletions(failing, Date.now(), 1);
    }
    expect(errors.mock.calls.some((c) => String(c[0]).includes("account_deletion_failing"))).toBe(
      true,
    );
    errors.mockRestore();
    warn.mockRestore();
    // Once storage works again it completes (after the failed deletes' claims lapse).
    await sql("update users set deletion_next_at = null where id = ?", stuck.user.id);
    await lapseClaims();
    expect((await sweepAccountDeletions(env, Date.now(), 1)).done).toBe(1);
  });
});

describe("finding 5: no sign-in family survives the lock", () => {
  it("refuses new tokens and rotated successors once the account is locked", async () => {
    const owner = await signIn();
    const token = await one<{ id: string; family_id: string; user_id: string }>(
      "select id, family_id, user_id from refresh_tokens where user_id = ?",
      owner.user.id,
    );
    await requestAccountDeletion(env.DB, owner.user.id);
    await expect(issueTokenPair(db(), owner.user.id, env.JWT_SIGNING_KEY)).rejects.toBeInstanceOf(
      AccountDeleting,
    );
    // A rotation that read its token before the lock writes no successor after it.
    if (!token) throw new Error("no token");
    await sql(
      "insert into refresh_tokens (id, user_id, token_hash, expires_at, created_at, family_id) values (?, ?, ?, ?, ?, ?)",
      token.id,
      owner.user.id,
      "synthetic-hash",
      Date.now() + 60_000,
      Date.now(),
      token.family_id,
    );
    await consumeRefreshToken(db(), { id: token.id, userId: owner.user.id }, "successor");
    const rows = await one<{ n: number }>(
      "select count(*) as n from refresh_tokens where user_id = ? and revoked_at is null",
      owner.user.id,
    );
    expect(rows?.n).toBe(0);
    expect(
      (await api("/me", { headers: { authorization: `Bearer ${owner.accessToken}` } })).status,
    ).toBe(401);
  });
});

describe("extra review of #78", () => {
  async function sessionAt(userId: string, revision = 0) {
    const id = crypto.randomUUID();
    await insertSession(db(), { id, userId, revision, fields });
    return id;
  }
  const rowKey = async (id: string) =>
    (await one<{ k: string | null }>("select track_key as k from sessions where id = ?", id))?.k ??
    null;
  const bytes = new Uint8Array([0x1f, 0x8b, 1]);

  it("1: a failure after the attach committed never deletes the new object", async () => {
    const owner = await signIn();
    const id = await sessionAt(owner.user.id);
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    await expect(
      storeTrack(
        db(),
        env.TRACKS,
        { id, userId: owner.user.id, revision: 0, key, bytes },
        {
          readBack: async () => {
            throw new Error("synthetic D1 read failure");
          },
        },
      ),
    ).rejects.toBeInstanceOf(AfterCommit);
    expect(await rowKey(id)).toBe(key);
    expect(await env.TRACKS.head(key)).not.toBeNull();
    // Even a discard after an ambiguous failure deletes nothing: the record is gone.
    await discardUpload(db(), env.TRACKS, key, owner.user.id);
    expect(await env.TRACKS.head(key)).not.toBeNull();
  });

  it("2: a collector that claimed an upload's record first wins; the attach then fails", async () => {
    const owner = await signIn();
    const id = await sessionAt(owner.user.id);
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    const result = await storeTrack(
      db(),
      env.TRACKS,
      { id, userId: owner.user.id, revision: 0, key, bytes },
      {
        afterPut: async () => {
          // A collector took the record as stale (a very slow upload) and is about to
          // delete the object: it holds the claim.
          await sql(
            "update pending_r2_deletes set claim = 'collector', claimed_at = ? where key = ?",
            Date.now(),
            key,
          );
        },
      },
    );
    expect(result.kind).toBe("expired");
    expect(await rowKey(id)).toBeNull();
    // The collector's claim is intact, so it goes on to delete the object safely.
    const record = await one<{ claim: string }>(
      "select claim from pending_r2_deletes where key = ?",
      key,
    );
    expect(record?.claim).toBe("collector");
  });

  it("2: once an upload attached, a collector holding its stale key deletes nothing", async () => {
    const owner = await signIn();
    const id = await sessionAt(owner.user.id);
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    // The collector selected the key while it was stale...
    const stale = [key];
    const result = await storeTrack(db(), env.TRACKS, {
      id,
      userId: owner.user.id,
      revision: 0,
      key,
      bytes,
    });
    expect(result.kind).toBe("attached");
    // ...and claims it after the attach consumed the record: it wins nothing.
    expect(await claimAndDelete(env.DB, env.TRACKS, stale, { before: Date.now() + 1 })).toEqual([]);
    expect(await env.TRACKS.head(key)).not.toBeNull();
    expect(await rowKey(id)).toBe(key);
  });

  it("3: the final pass waits for a young upload record instead of orphaning its object", async () => {
    const owner = await signIn();
    const id = await sessionAt(owner.user.id);
    const requestedAt = Date.now() - DELETION_GRACE_MS - 1000;
    await requestAccountDeletion(env.DB, owner.user.id, requestedAt);
    // An upload authorized before the lock recorded its key just now; its put lands late.
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    await sql(
      "insert into pending_r2_deletes (key, user_id, created_at) values (?, ?, ?)",
      key,
      owner.user.id,
      Date.now(),
    );
    expect(await runAccountDeletion(env, owner.user.id)).toBe("pending");
    await env.TRACKS.put(key, "late put");
    // The account record stays (still locked) until the record is past the grace.
    expect(await one("select id from users where id = ?", owner.user.id)).not.toBeNull();
    const later = Date.now() + UPLOAD_GRACE_MS + 1000;
    expect(await runAccountDeletion(env, owner.user.id, later)).toBe("done");
    expect(await env.TRACKS.head(key)).toBeNull();
    expect(
      await one("select key from pending_r2_deletes where user_id = ?", owner.user.id),
    ).toBeNull();
    expect(await one("select id from users where id = ?", owner.user.id)).toBeNull();
  });

  it("4: a request with the account's token no longer tries to finish the deletion", async () => {
    const owner = await signIn();
    await requestAccountDeletion(env.DB, owner.user.id, Date.now() - DELETION_GRACE_MS - 1000);
    const response = await api("/me", {
      headers: { authorization: `Bearer ${owner.accessToken}` },
    });
    expect(response.status).toBe(401);
    // Only a sign-in for the Apple ID, or the cron, finishes it.
    expect(await one("select id from users where id = ?", owner.user.id)).not.toBeNull();
  });

  it("5: an upload removes fixed-key tracks from before per-upload keys", async () => {
    const owner = await signIn();
    const id = await sessionAt(owner.user.id, 2);
    const prefix = `${userPrefix(owner.user.id)}sessions/${id}/`;
    // Left behind by a cleanup that failed before the upgrade; no ledger row knows them.
    for (const name of ["track.v1.gz", "track.v1.r1.gz"])
      await env.TRACKS.put(prefix + name, "old");
    const key = trackKey(userPrefix(owner.user.id), id, 2);
    expect(
      (await storeTrack(db(), env.TRACKS, { id, userId: owner.user.id, revision: 2, key, bytes }))
        .kind,
    ).toBe("attached");
    const left = (await env.TRACKS.list({ prefix })).objects.map((o) => o.key);
    expect(left).toEqual([key]);

    // And a newer revision's metadata, which detaches the track, does the same.
    await env.TRACKS.put(`${prefix}track.v1.r2.gz`, "old");
    await replaceSessionMetadata(db(), env.TRACKS, {
      id,
      userId: owner.user.id,
      revision: 3,
      fields,
    });
    expect((await env.TRACKS.list({ prefix })).objects).toHaveLength(0);
  });
});

describe("last review of #78", () => {
  const rowKey = async (id: string) =>
    (await one<{ k: string | null }>("select track_key as k from sessions where id = ?", id))?.k ??
    null;
  const bytes = new Uint8Array([0x1f, 0x8b, 2]);

  /** env.TRACKS whose `delete` deletes, then reports a failure anyway. */
  const lyingBucket = () =>
    new Proxy(env.TRACKS, {
      get(target, property) {
        if (property === "delete") {
          return async (keys: string | string[]) => {
            await target.delete(keys);
            throw new Error("synthetic R2 failure after deleting");
          };
        }
        const value = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      },
    }) as R2Bucket;

  it("1: a key whose delete reported failure stays claimed, so a paused upload cannot attach it", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await insertSession(db(), { id, userId: owner.user.id, revision: 0, fields });
    const first = trackKey(userPrefix(owner.user.id), id, 0);
    const stored = await storeTrack(db(), env.TRACKS, {
      id,
      userId: owner.user.id,
      revision: 0,
      key: first,
      bytes,
    });
    expect(stored.kind).toBe("attached");

    const second = trackKey(userPrefix(owner.user.id), id, 0);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const result = await storeTrack(
      db(),
      env.TRACKS,
      { id, userId: owner.user.id, revision: 0, key: second, bytes },
      {
        afterPut: async () => {
          // The upload pauses past the grace; a collector deletes its object, and R2 says
          // the delete failed although it went through.
          await sql(
            "update pending_r2_deletes set created_at = ? where key = ?",
            Date.now() - UPLOAD_GRACE_MS - 1000,
            second,
          );
          await expect(
            collectR2Garbage(db(), lyingBucket(), {
              userId: owner.user.id,
              before: Date.now() - UPLOAD_GRACE_MS,
            }),
          ).rejects.toThrow("synthetic R2 failure");
        },
      },
    );
    warn.mockRestore();
    // The upload resumes: its record is still claimed, so it does not attach the missing
    // object, and the previous track stays attached and stored.
    expect(result.kind).toBe("expired");
    expect(await env.TRACKS.head(second)).toBeNull();
    expect(await rowKey(id)).toBe(first);
    expect(await env.TRACKS.head(first)).not.toBeNull();
    const record = await one<{ claim: string | null }>(
      "select claim from pending_r2_deletes where key = ?",
      second,
    );
    expect(record?.claim).not.toBeNull();
    // Once the claim lapses a collector retries the (idempotent) delete and clears it.
    await lapseClaims();
    expect(await collectR2Garbage(db(), env.TRACKS, { userId: owner.user.id })).toBe(1);
    expect(await pending(owner.user.id)).toEqual([]);
    expect(await env.TRACKS.head(first)).not.toBeNull();
  });

  it("2: an upload that lost its record deletes its own object, or records it again", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    await insertSession(db(), { id, userId: owner.user.id, revision: 0, fields });
    const key = trackKey(userPrefix(owner.user.id), id, 0);
    const lostRecord = {
      afterPut: async () => {
        // Collected (and the prefix swept) before this put landed: no record is left.
        await sql("delete from pending_r2_deletes where key = ?", key);
      },
    };
    const input = { id, userId: owner.user.id, revision: 0, key, bytes };
    expect((await storeTrack(db(), env.TRACKS, input, lostRecord)).kind).toBe("expired");
    expect(await env.TRACKS.head(key)).not.toBeNull();
    await discardUpload(db(), env.TRACKS, key, owner.user.id);
    expect(await env.TRACKS.head(key)).toBeNull();
    expect(await pending(owner.user.id)).toEqual([]);

    // The delete fails, and the account is gone by then: the key is recorded again, and the
    // cron's collection (all users, past the upload grace) deletes it.
    const again = trackKey(userPrefix(owner.user.id), id, 0);
    const input2 = { ...input, key: again };
    const lost2 = {
      afterPut: async () => void (await sql("delete from pending_r2_deletes where key = ?", again)),
    };
    expect((await storeTrack(db(), env.TRACKS, input2, lost2)).kind).toBe("expired");
    await sql("delete from users where id = ?", owner.user.id);
    await expect(
      discardUpload(
        db(),
        flakyBucket(() => true),
        again,
        owner.user.id,
      ),
    ).rejects.toThrow("synthetic R2 failure");
    expect(await pending(owner.user.id)).toEqual([again]);
    await collectR2Garbage(db(), env.TRACKS, { before: Date.now() - UPLOAD_GRACE_MS });
    expect(await env.TRACKS.head(again)).toBeNull();
    expect(await pending(owner.user.id)).toEqual([]);

    // A key a row names is never deleted, even with its record gone.
    const named = await signIn();
    const sid = crypto.randomUUID();
    await insertSession(db(), { id: sid, userId: named.user.id, revision: 0, fields });
    const attached = trackKey(userPrefix(named.user.id), sid, 0);
    await storeTrack(db(), env.TRACKS, {
      id: sid,
      userId: named.user.id,
      revision: 0,
      key: attached,
      bytes,
    });
    await discardUpload(db(), env.TRACKS, attached, named.user.id);
    expect(await env.TRACKS.head(attached)).not.toBeNull();
  });
});

describe("account deletion with account exports (#79)", () => {
  it("removes the account's export jobs and their files, and a locked account cannot start one", async () => {
    const owner = await signIn();
    await sessionWithKey(owner.user.id, `${userPrefix(owner.user.id)}sessions/<id>/track.v1.gz`);
    const storage = { DB: env.DB, TRACKS: env.TRACKS };
    const created = await createExportJob(storage, owner.user.id);
    if (created.kind !== "created") throw new Error(created.kind);
    let next: Awaited<ReturnType<typeof runExportStep>> = firstMessage(created.job);
    while (next) next = await runExportStep(storage, next);
    const prefix = `${userPrefix(owner.user.id)}exports/`;
    expect((await env.TRACKS.list({ prefix })).objects.length).toBeGreaterThan(1);

    expect(await requestAccountDeletion(env.DB, owner.user.id)).toBe(true);
    expect((await createExportJob(storage, owner.user.id)).kind).toBe("account_gone");
    // The first pass (still inside the grace period) already removes the jobs and files.
    expect(await runAccountDeletion(env, owner.user.id)).toBe("pending");
    expect(await one("select id from export_jobs where user_id = ?", owner.user.id)).toBeNull();
    expect((await env.TRACKS.list({ prefix })).objects).toHaveLength(0);
    expect(
      await runAccountDeletion(env, owner.user.id, Date.now() + DELETION_GRACE_MS + 1000),
    ).toBe("done");
    expect(await one("select id from users where id = ?", owner.user.id)).toBeNull();
  });
});
