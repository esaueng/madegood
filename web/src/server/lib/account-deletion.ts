import { and, eq, isNotNull, isNull, lte } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { privacyZones, refreshTokens, sessions, users, voyages } from "../db/schema";
import { purgeAccountVoyages } from "../live/registry";
import { deletePrefix, userPrefix } from "./storage";

// Account deletion (DELETE /api/me) as a durable job.
//
// The request marks the user row deleting (`users.deleted_at`) and deletes every refresh
// token in one D1 batch. From then on the account cannot sign in (findOrCreateUser), no
// write is accepted for it (requireAuth), no post-processing touches it (postprocess.ts),
// and its website cookies and app refresh tokens are dead. The marked row is the job.
//
// `runAccountDeletion` then removes the data. Every step is idempotent, so a failure at
// any point is simply repeated: the request starts one run (waitUntil), and the scheduled
// sweep runs every pending deletion until it completes. Session track keys come from the
// session rows, which are deleted only after their objects. Only once DELETION_GRACE_MS has
// passed since the request (longer than an access token lives, so no write that was
// already authorized can still be in flight) does a run sweep the R2 prefix one last time
// and delete the user row, which cascades to tombstones and anything left.

/** Longer than an access token's 15 minutes: writes authorized before deletion are over. */
export const DELETION_GRACE_MS = 20 * 60 * 1000;
/** Deletions one scheduled run works on. */
export const DELETION_SWEEP_LIMIT = 25;

type DeletionEnv = Pick<Env, "DB" | "TRACKS"> & Partial<Pick<Env, "VOYAGE_LIVE">>;

/**
 * Marks the account deleting and revokes its sign-ins. Returns false when the account is
 * already gone. Repeating it keeps the first request time.
 */
export async function requestAccountDeletion(
  db: D1Database,
  userId: string,
  now = Date.now(),
): Promise<boolean> {
  const orm = drizzle(db);
  const [, , [row]] = await orm.batch([
    orm
      .update(users)
      .set({ deletedAt: now })
      .where(and(eq(users.id, userId), isNull(users.deletedAt))),
    orm.delete(refreshTokens).where(eq(refreshTokens.userId, userId)),
    orm.select({ deletedAt: users.deletedAt }).from(users).where(eq(users.id, userId)),
  ]);
  return row !== undefined;
}

export type DeletionResult = "none" | "pending" | "done";

/**
 * One idempotent pass over a deleting account. Returns `done` once the user row is gone,
 * `pending` while the grace period runs, `none` when the account is not being deleted.
 * Throws on any storage failure; the next pass starts over safely.
 */
export async function runAccountDeletion(
  env: DeletionEnv,
  userId: string,
  now = Date.now(),
): Promise<DeletionResult> {
  const db = drizzle(env.DB);
  const [user] = await db
    .select({ deletedAt: users.deletedAt })
    .from(users)
    .where(eq(users.id, userId));
  if (!user) return "done";
  if (user.deletedAt === null) return "none";

  // Objects first, then the rows that name them, so a failure never loses a key.
  const prefix = userPrefix(userId);
  const tracked = await db
    .select({ id: sessions.id, key: sessions.trackKey })
    .from(sessions)
    .where(and(eq(sessions.userId, userId), isNotNull(sessions.trackKey)));
  const outside = tracked.flatMap((t) => (t.key && !t.key.startsWith(prefix) ? [t.key] : []));
  for (let i = 0; i < outside.length; i += 1000) {
    await env.TRACKS.delete(outside.slice(i, i + 1000));
  }
  await deletePrefix(env.TRACKS, prefix);
  if (env.VOYAGE_LIVE) await purgeAccountVoyages(env as Env, userId);
  await db.batch([
    db.delete(sessions).where(eq(sessions.userId, userId)),
    db.delete(privacyZones).where(eq(privacyZones.userId, userId)),
    db.delete(voyages).where(eq(voyages.userId, userId)),
    db.delete(refreshTokens).where(eq(refreshTokens.userId, userId)),
  ]);

  if (now - user.deletedAt < DELETION_GRACE_MS) return "pending";
  // Last sweep after the grace period: an upload that was in flight has landed by now.
  await deletePrefix(env.TRACKS, prefix);
  await db.delete(users).where(and(eq(users.id, userId), isNotNull(users.deletedAt)));
  return "done";
}

/** Scheduled: runs the oldest pending deletions; one failure does not stop the others. */
export async function sweepAccountDeletions(
  env: DeletionEnv,
  now = Date.now(),
  limit = DELETION_SWEEP_LIMIT,
): Promise<{ done: number; pending: number; failed: number }> {
  const pending = await drizzle(env.DB)
    .select({ id: users.id })
    .from(users)
    .where(and(isNotNull(users.deletedAt), lte(users.deletedAt, now)))
    .orderBy(users.deletedAt)
    .limit(limit);
  const counts = { done: 0, pending: 0, failed: 0 };
  for (const { id } of pending) {
    try {
      const result = await runAccountDeletion(env, id, now);
      if (result === "done") counts.done += 1;
      else counts.pending += 1;
    } catch (error) {
      console.error("Account deletion failed; the next sweep retries it.", error);
      counts.failed += 1;
    }
  }
  return counts;
}
