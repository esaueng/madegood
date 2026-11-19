import { and, eq, isNull } from "drizzle-orm";
import type { drizzle } from "drizzle-orm/d1";
import { type Session, sessions, users } from "../db/schema";
import { CLEARED_DERIVED } from "./postprocess";
import {
  collectKeys,
  collectR2Garbage,
  discardKey,
  keysOf,
  recordKey,
  recordSessionTrackKeys,
  selectSessionTrackKeys,
  UPLOAD_GRACE_MS,
} from "./r2-garbage";
import { TRACK_CONTENT_TYPE } from "./track";

type Db = ReturnType<typeof drizzle>;

/** The header a 412 carries: the revision the server stores for the session. */
export const UPLOAD_REVISION_HEADER = "Upload-Revision";

export type SessionFields = Pick<
  Session,
  | "sport"
  | "startedAt"
  | "endedAt"
  | "durationS"
  | "movingS"
  | "distanceM"
  | "maxSpeedMps"
  | "avgSpeedMps"
  | "summaryJson"
  | "analyzerVersion"
>;

export type ReplaceResult =
  | { kind: "updated"; session: Session }
  | { kind: "stale"; stored: number }
  | { kind: "missing" };

/** SQL: the account `?` exists and is not being deleted (lib/account-deletion.ts). */
export const ACTIVE_ACCOUNT =
  "EXISTS (SELECT 1 FROM users WHERE users.id = ? AND users.deleted_at IS NULL)";

/** `SET` assignments that clear what post-processing derived from the attached track. */
const CLEAR_DERIVED_SQL = Object.keys(CLEARED_DERIVED)
  .map(
    (field) => `${(sessions as unknown as Record<string, { name: string }>)[field]?.name} = NULL`,
  )
  .join(", ");

/** Collects this user's recorded objects old enough that no upload can still attach them. */
export async function collectUserGarbage(db: Db, bucket: R2Bucket, userId: string) {
  try {
    await collectR2Garbage(db, bucket, {
      userId,
      before: Date.now() - UPLOAD_GRACE_MS,
      limit: 100,
    });
  } catch (error) {
    console.warn("Could not collect old track objects; the scheduled sweep retries.", error);
  }
}

/**
 * Replaces the caller's metadata for an existing session with compare-and-swap on the
 * revision read:
 * - a lower revision than stored is stale;
 * - the same revision updates the fields and never touches the track;
 * - a strictly newer revision updates the fields and detaches the track, but only if the
 *   row is still at the revision read. The detached key is recorded for deletion in the
 *   same D1 batch (lib/r2-garbage.ts), so no later reader has to find it in the row.
 * Every write requires an active account in the same statement. A lost race re-reads and
 * decides again. `hooks.afterRead` lets tests interleave.
 */
export async function replaceSessionMetadata(
  db: Db,
  bucket: R2Bucket,
  input: { id: string; userId: string; revision: number; fields: SessionFields },
  hooks: { afterRead?: () => Promise<void> } = {},
): Promise<ReplaceResult> {
  const { id, userId, revision, fields } = input;
  const own = and(eq(sessions.id, id), eq(sessions.userId, userId), isNull(sessions.deletedAt));
  const d1 = db.$client;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const [current] = await db
      .select({ uploadRevision: sessions.uploadRevision })
      .from(sessions)
      .where(own);
    if (!current) return { kind: "missing" };
    if (current.uploadRevision > revision) return { kind: "stale", stored: current.uploadRevision };
    await hooks.afterRead?.();
    const newer = revision > current.uploadRevision;
    const now = Date.now();
    const at = `id = ? AND user_id = ? AND deleted_at IS NULL AND upload_revision = ? AND ${ACTIVE_ACCOUNT}`;
    const atBinds = [id, userId, current.uploadRevision, userId];
    const values = [
      fields.sport,
      fields.startedAt,
      fields.endedAt,
      fields.durationS,
      fields.movingS,
      fields.distanceM,
      fields.maxSpeedMps,
      fields.avgSpeedMps,
      fields.summaryJson,
      fields.analyzerVersion,
    ];
    const set =
      "sport = ?, started_at = ?, ended_at = ?, duration_s = ?, moving_s = ?, distance_m = ?, " +
      "max_speed_mps = ?, avg_speed_mps = ?, summary_json = ?, analyzer_version = ?, " +
      "upload_revision = ?, updated_at = ?" +
      (newer ? `, track_key = NULL, track_etag = NULL, ${CLEAR_DERIVED_SQL}` : "");
    const results = await d1.batch([
      ...(newer
        ? [selectSessionTrackKeys(d1, at, atBinds), recordSessionTrackKeys(d1, at, atBinds, now)]
        : []),
      d1
        .prepare(`UPDATE sessions SET ${set} WHERE ${at}`)
        .bind(...values, revision, now, ...atBinds),
    ]);
    if (results.at(-1)?.meta.changes !== 1) {
      if (!(await accountActive(db, userId))) return { kind: "missing" };
      continue;
    }
    const [updated] = await db.select().from(sessions).where(own);
    if (!updated) return { kind: "missing" };
    if (newer) {
      // The detached track goes now (its data may be what the user has trimmed away);
      // older recorded leftovers of the user go once no upload can still attach them.
      await collectKeys(db, bucket, keysOf(results[0]));
      await collectUserGarbage(db, bucket, userId);
    }
    return { kind: "updated", session: updated };
  }
  const [now] = await db
    .select({ uploadRevision: sessions.uploadRevision })
    .from(sessions)
    .where(own);
  return now ? { kind: "stale", stored: now.uploadRevision } : { kind: "missing" };
}

/**
 * Creates the session with the account's default visibility, in one statement that also
 * requires the account to be active (INSERT ... SELECT FROM users). Returns null when the
 * ID is taken or the account is gone or being deleted.
 */
export async function insertSession(
  db: Db,
  input: { id: string; userId: string; revision: number; fields: SessionFields },
): Promise<Session | null> {
  const { id, userId, revision, fields } = input;
  const result = await db.$client
    .prepare(
      `INSERT INTO sessions (id, user_id, visibility, upload_revision, sport, started_at,
         ended_at, duration_s, moving_s, distance_m, max_speed_mps, avg_speed_mps,
         summary_json, analyzer_version)
       SELECT ?, id, default_visibility, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
       FROM users WHERE id = ? AND deleted_at IS NULL
       ON CONFLICT (id) DO NOTHING`,
    )
    .bind(
      id,
      revision,
      fields.sport,
      fields.startedAt,
      fields.endedAt,
      fields.durationS,
      fields.movingS,
      fields.distanceM,
      fields.maxSpeedMps,
      fields.avgSpeedMps,
      fields.summaryJson,
      fields.analyzerVersion,
      userId,
    )
    .run();
  if (result.meta.changes !== 1) return null;
  const [created] = await db
    .select()
    .from(sessions)
    .where(and(eq(sessions.id, id), eq(sessions.userId, userId)));
  return created ?? null;
}

/**
 * Deletes the caller's session row and records its track key in the same batch; with
 * `tombstone` also writes the tombstone, only if a row was deleted. Returns whether one was.
 */
export async function deleteSessionRow(
  db: Db,
  bucket: R2Bucket,
  id: string,
  userId: string,
  options: { tombstone?: boolean } = {},
): Promise<boolean> {
  const d1 = db.$client;
  const now = Date.now();
  const where = "id = ? AND user_id = ?";
  const results = await d1.batch([
    selectSessionTrackKeys(d1, where, [id, userId]),
    recordSessionTrackKeys(d1, where, [id, userId], now),
    d1.prepare("DELETE FROM sessions WHERE id = ? AND user_id = ?").bind(id, userId),
    ...(options.tombstone
      ? [
          d1
            .prepare(
              `INSERT OR IGNORE INTO session_tombstones (id, user_id, deleted_at)
               SELECT ?, ?, ? WHERE changes() = 1`,
            )
            .bind(id, userId, now),
        ]
      : []),
  ]);
  await collectKeys(db, bucket, keysOf(results[0]));
  return results[2]?.meta.changes === 1;
}

export type StoreResult =
  /** `replaced`: a concurrent upload of the same revision attached after this one. */
  { kind: "attached"; etag: string; httpEtag: string; replaced: boolean } | { kind: "detached" };

/**
 * Stores a track under its own key (unique per upload attempt) and attaches it while the
 * row is still at `revision` and the account is active:
 * 1. the key is recorded for deletion before the put (lib/r2-garbage.ts), so an object
 *    that never attaches is always collected, whatever fails after;
 * 2. one D1 batch records the key being replaced, attaches the new one (compare-and-swap
 *    on the row's revision and the account) and removes the new key's record if it
 *    attached.
 * No two uploads share a key, so cleanup after a failure deletes only its own object.
 * `hooks` let tests interleave.
 */
export async function storeTrack(
  db: Db,
  bucket: R2Bucket,
  input: { id: string; userId: string; revision: number; key: string; bytes: Uint8Array },
  hooks: { afterPut?: () => Promise<void>; afterAttach?: () => Promise<void> } = {},
): Promise<StoreResult> {
  const { id, userId, revision, key, bytes } = input;
  const d1 = db.$client;
  await recordKey(d1, key, userId).run();
  const object = await bucket.put(key, bytes, {
    httpMetadata: { contentType: TRACK_CONTENT_TYPE },
  });
  await hooks.afterPut?.();
  const now = Date.now();
  const at = `id = ? AND user_id = ? AND deleted_at IS NULL AND upload_revision = ? AND ${ACTIVE_ACCOUNT}`;
  const atBinds = [id, userId, revision, userId];
  const replaced = `${at} AND track_key <> ?`;
  const results = await d1.batch([
    selectSessionTrackKeys(d1, replaced, [...atBinds, key]),
    recordSessionTrackKeys(d1, replaced, [...atBinds, key], now),
    d1
      .prepare(
        `UPDATE sessions SET track_key = ?, track_etag = ?, ${CLEAR_DERIVED_SQL}, updated_at = ?
         WHERE ${at}`,
      )
      .bind(key, object.etag, now, ...atBinds),
    d1.prepare("DELETE FROM pending_r2_deletes WHERE key = ? AND changes() = 1").bind(key),
  ]);
  if (results[2]?.meta.changes !== 1) return { kind: "detached" };
  // The track this one replaced goes now; it was attached, so no upload is still writing it.
  await collectKeys(db, bucket, keysOf(results[0]));
  await hooks.afterAttach?.();
  const [row] = await db
    .select({ key: sessions.trackKey })
    .from(sessions)
    .where(and(eq(sessions.id, id), eq(sessions.userId, userId)));
  await collectUserGarbage(db, bucket, userId);
  return {
    kind: "attached",
    etag: object.etag,
    httpEtag: object.httpEtag,
    replaced: row?.key !== key,
  };
}

/** Deletes an upload's own object that did not attach (and its record). */
export const discardUpload = (db: Db, bucket: R2Bucket, key: string) => discardKey(db, bucket, key);

/** Whether the account exists and is not being deleted (lib/account-deletion.ts). */
export async function accountActive(db: Db, userId: string): Promise<boolean> {
  const [row] = await db
    .select({ id: users.id })
    .from(users)
    .where(and(eq(users.id, userId), isNull(users.deletedAt)));
  return row !== undefined;
}
