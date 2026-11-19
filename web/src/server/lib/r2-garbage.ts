import { and, asc, eq, inArray, lte } from "drizzle-orm";
import type { drizzle } from "drizzle-orm/d1";
import { pendingR2Deletes } from "../db/schema";

// The R2 garbage ledger (`pending_r2_deletes`). An object key goes in when nothing may
// reference it any more, in the same D1 batch as the change that stops a row naming it
// (a new revision detaching a track, a session or account deletion), or before an upload
// writes it (removed again in the batch that attaches it). So every object that a row
// does not name is recorded somewhere, whatever fails in between, and cleanup never needs
// to read a track key that a concurrent request may already have cleared.
//
// Collecting deletes the objects first, then their rows: a failure leaves the rows for the
// next collection. Deleting a key that is already gone is harmless.

type Db = ReturnType<typeof drizzle>;

/** How long a recorded upload key is left alone: longer than any upload takes to attach. */
export const UPLOAD_GRACE_MS = 15 * 60 * 1000;

/**
 * The statement that records the track key(s) of the sessions matching `where` (raw SQL
 * over `sessions`, with `binds`), for use in the same batch as the change that detaches them.
 */
export function recordSessionTrackKeys(
  d1: D1Database,
  where: string,
  binds: unknown[],
  now = Date.now(),
): D1PreparedStatement {
  return d1
    .prepare(
      `INSERT OR IGNORE INTO pending_r2_deletes (key, user_id, created_at)
       SELECT track_key, user_id, ? FROM sessions WHERE track_key IS NOT NULL AND (${where})`,
    )
    .bind(now, ...binds);
}

/** The companion read for the same batch: which keys `recordSessionTrackKeys` records. */
export function selectSessionTrackKeys(
  d1: D1Database,
  where: string,
  binds: unknown[],
): D1PreparedStatement {
  return d1
    .prepare(`SELECT track_key AS key FROM sessions WHERE track_key IS NOT NULL AND (${where})`)
    .bind(...binds);
}

/** The keys a batch result of `selectSessionTrackKeys` returned. */
export const keysOf = (result: D1Result | undefined) =>
  ((result?.results ?? []) as { key: string }[]).map((r) => r.key);

/**
 * Collects specific recorded keys now: ones just detached from a row (never an upload in
 * flight). On failure their records stay for the next collection.
 */
export async function collectKeys(db: Db, bucket: R2Bucket, keys: string[]): Promise<void> {
  if (keys.length === 0) return;
  try {
    await bucket.delete(keys);
    for (let i = 0; i < keys.length; i += 50) {
      await db.delete(pendingR2Deletes).where(inArray(pendingR2Deletes.key, keys.slice(i, i + 50)));
    }
  } catch (error) {
    console.warn("Could not delete detached tracks now; they stay recorded.", error);
  }
}

/** Records one key before an upload writes it. */
export function recordKey(d1: D1Database, key: string, userId: string, now = Date.now()) {
  return d1
    .prepare("INSERT OR IGNORE INTO pending_r2_deletes (key, user_id, created_at) VALUES (?, ?, ?)")
    .bind(key, userId, now);
}

/**
 * Deletes recorded objects and then their rows: the oldest `limit`, of one user or all, and
 * only those recorded before `before` (so an upload in flight keeps its object until it
 * has had time to attach). Returns how many keys were collected.
 */
export async function collectR2Garbage(
  db: Db,
  bucket: R2Bucket,
  options: { userId?: string; before?: number; limit?: number } = {},
): Promise<number> {
  const limit = options.limit ?? 1000;
  const conditions = [];
  if (options.userId !== undefined) conditions.push(eq(pendingR2Deletes.userId, options.userId));
  if (options.before !== undefined)
    conditions.push(lte(pendingR2Deletes.createdAt, options.before));
  let collected = 0;
  for (;;) {
    const rows = await db
      .select({ key: pendingR2Deletes.key })
      .from(pendingR2Deletes)
      .where(conditions.length > 0 ? and(...conditions) : undefined)
      .orderBy(asc(pendingR2Deletes.createdAt), asc(pendingR2Deletes.key))
      .limit(Math.min(limit - collected, 1000));
    if (rows.length === 0) return collected;
    const keys = rows.map((r) => r.key);
    await bucket.delete(keys);
    for (let i = 0; i < keys.length; i += 50) {
      await db.delete(pendingR2Deletes).where(inArray(pendingR2Deletes.key, keys.slice(i, i + 50)));
    }
    collected += keys.length;
    if (collected >= limit || rows.length < 1000) return collected;
  }
}

/** Deletes one recorded key now (an upload discarding its own object). */
export async function discardKey(db: Db, bucket: R2Bucket, key: string): Promise<void> {
  await bucket.delete(key);
  await db.delete(pendingR2Deletes).where(eq(pendingR2Deletes.key, key));
}
