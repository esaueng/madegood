import { and, asc, eq, isNull, lt, lte, or } from "drizzle-orm";
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
//
// A claim is one-way: once a row is claimed it is never unclaimed, so a key a collector has
// started deleting can never attach afterwards (R2 may delete an object and still report a
// failure). A claim that lapses is only taken over by the next collector, which retries the
// delete.

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
  // A key a row names is attached, never an upload still being written, so it may be
  // collected at once: it is recorded as already past the upload grace.
  now -= UPLOAD_GRACE_MS + 1;
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

/** How long a claim protects a key; a collector that died is replaced after this. */
export const CLAIM_LEASE_MS = 10 * 60 * 1000;

/**
 * Claims recorded keys and deletes their objects: one conditional UPDATE ... RETURNING
 * takes the rows nobody holds (or whose claim lapsed), and only the objects of rows this
 * call won are deleted, then those rows. An upload attaches its key only while its row is
 * unclaimed (session-upload.ts), so no collector can delete an object that is attached, or
 * becomes attached. Returns the keys deleted. On an R2 failure the rows stay claimed (the
 * object may be gone already), and a collector retries once the claim lapses.
 */
export async function claimAndDelete(
  d1: D1Database,
  bucket: R2Bucket,
  keys: string[],
  options: { before?: number; now?: number } = {},
): Promise<string[]> {
  if (keys.length === 0) return [];
  const now = options.now ?? Date.now();
  const claim = crypto.randomUUID();
  const won: string[] = [];
  for (let i = 0; i < keys.length; i += 90) {
    const chunk = keys.slice(i, i + 90);
    const placeholders = chunk.map(() => "?").join(", ");
    const { results } = await d1
      .prepare(
        `UPDATE pending_r2_deletes SET claim = ?, claimed_at = ?
         WHERE key IN (${placeholders})
           AND (claim IS NULL OR claimed_at < ?)
           AND created_at <= ?
         RETURNING key`,
      )
      .bind(claim, now, ...chunk, now - CLAIM_LEASE_MS, options.before ?? now)
      .all<{ key: string }>();
    won.push(...results.map((r) => r.key));
  }
  if (won.length === 0) return [];
  // Never handed back on failure: see the claim rule above.
  for (let i = 0; i < won.length; i += 1000) await bucket.delete(won.slice(i, i + 1000));
  for (let i = 0; i < won.length; i += 90) {
    const chunk = won.slice(i, i + 90);
    await d1
      .prepare(
        `DELETE FROM pending_r2_deletes WHERE claim = ? AND key IN (${chunk.map(() => "?").join(", ")})`,
      )
      .bind(claim, ...chunk)
      .run();
  }
  return won;
}

/**
 * Collects specific recorded keys now: ones just detached from a row (never an upload in
 * flight). On failure their records stay for the next collection.
 */
export async function collectKeys(db: Db, bucket: R2Bucket, keys: string[]): Promise<void> {
  try {
    await claimAndDelete(db.$client, bucket, keys);
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
 * Collects recorded objects: the oldest `limit`, of one user or all, and only those
 * recorded before `before` (so an upload in flight keeps its object until it has had time
 * to attach). Each key is claimed first (`claimAndDelete`). Returns how many were collected.
 */
export async function collectR2Garbage(
  db: Db,
  bucket: R2Bucket,
  options: { userId?: string; before?: number; limit?: number } = {},
): Promise<number> {
  const limit = options.limit ?? 1000;
  const now = Date.now();
  const before = options.before ?? now;
  const conditions = [
    lte(pendingR2Deletes.createdAt, before),
    or(isNull(pendingR2Deletes.claim), lt(pendingR2Deletes.claimedAt, now - CLAIM_LEASE_MS)),
  ];
  if (options.userId !== undefined) conditions.push(eq(pendingR2Deletes.userId, options.userId));
  let collected = 0;
  for (;;) {
    const rows = await db
      .select({ key: pendingR2Deletes.key })
      .from(pendingR2Deletes)
      .where(and(...conditions))
      .orderBy(asc(pendingR2Deletes.createdAt), asc(pendingR2Deletes.key))
      .limit(Math.min(limit - collected, 1000));
    if (rows.length === 0) return collected;
    const won = await claimAndDelete(
      db.$client,
      bucket,
      rows.map((r) => r.key),
      { before, now },
    );
    collected += won.length;
    if (collected >= limit || rows.length < 1000 || won.length === 0) return collected;
  }
}

/**
 * Deletes an upload's own object if it never attached: the upload claims its own row like a
 * collector, so after an attach (row gone) or a collector's claim it deletes nothing, even
 * when the upload does not know whether its attach committed.
 */
export async function discardKey(db: Db, bucket: R2Bucket, key: string): Promise<boolean> {
  return (await claimAndDelete(db.$client, bucket, [key])).length > 0;
}
