import { and, asc, eq, isNotNull, isNull, lte, or, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { AccountDeleting } from "../auth/account-state";
import { findOrCreateUser } from "../auth/users";
import { pendingR2Deletes, type User, users } from "../db/schema";
import { purgeAccountVoyages } from "../live/registry";
import { logFailure } from "./logging";
import { collectR2Garbage, recordSessionTrackKeys, UPLOAD_GRACE_MS } from "./r2-garbage";
import { sharingAvailable } from "./sharing-available";
import { deletePrefix, userPrefix } from "./storage";

// Account deletion (DELETE /api/me) as a durable job.
//
// The request marks the user row deleting (`users.deleted_at`) and deletes every refresh
// token in one D1 batch. From then on every write requires an active account in its own
// statement (session, track, zone, voyage, live share, post-processing and refresh-token
// writes all carry the predicate), so nothing authorized before the lock can land after
// it; sign-in is refused; and the website cookies and app refresh tokens are dead.
//
// `runAccountDeletion` then removes the data. Object keys are never read from rows at sweep
// time alone: every key a row stops naming is recorded in `pending_r2_deletes` in the same
// batch as that change (lib/r2-garbage.ts), and the deletion pass records the keys of the
// rows it deletes in the batch that deletes them. Each pass collects the ledger, sweeps the
// user's prefix (export parts from #79 included) and purges live shares; every step is
// idempotent, so a failure is repeated by the next pass. Passes come from the request, the
// scheduled sweep (backoff per job, oldest due first), and from a sign-in attempt for the
// account's Apple ID once the grace period is over (where no cron runs, such as previews,
// that sign-in is what finishes the deletion; until then the Apple ID stays reserved). After
// DELETION_GRACE_MS (longer than an access token lives) a pass collects and sweeps one last
// time, then deletes the user row, which cascades to tombstones and export jobs.

/** Longer than an access token's 15 minutes: writes authorized before deletion are over. */
export const DELETION_GRACE_MS = 20 * 60 * 1000;
/** Deletions one scheduled run works on. */
export const DELETION_SWEEP_LIMIT = 25;
/** After this many failed passes a deletion is reported as failing on every attempt. */
export const DELETION_ALERT_ATTEMPTS = 8;
/** Backoff after a failed pass: 1, 2, 4 … minutes, at most 6 hours. */
export const deletionBackoffMs = (attempts: number) =>
  Math.min(60_000 * 2 ** Math.max(0, attempts - 1), 6 * 3600 * 1000);

type DeletionEnv = Pick<Env, "DB" | "TRACKS"> & Partial<Pick<Env, "VOYAGE_LIVE" | "SHARING">>;

/**
 * Marks the account deleting and revokes its sign-ins. Returns false when the account is
 * already gone. Repeating it keeps the first request time.
 */
export async function requestAccountDeletion(
  db: D1Database,
  userId: string,
  now = Date.now(),
): Promise<boolean> {
  const [, , found] = await db.batch([
    db
      .prepare(
        "UPDATE users SET deleted_at = ?, deletion_next_at = NULL WHERE id = ? AND deleted_at IS NULL",
      )
      .bind(now, userId),
    db.prepare("DELETE FROM refresh_tokens WHERE user_id = ?").bind(userId),
    db.prepare("SELECT 1 AS present FROM users WHERE id = ?").bind(userId),
  ]);
  return (found?.results.length ?? 0) > 0;
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

  // Rows go with their keys recorded in the same batch, so no later step needs the rows.
  const d1 = env.DB;
  await d1.batch([
    recordSessionTrackKeys(d1, "user_id = ?", [userId], now),
    d1.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userId),
    d1.prepare("DELETE FROM privacy_zones WHERE user_id = ?").bind(userId),
    d1.prepare("DELETE FROM voyages WHERE user_id = ?").bind(userId),
    d1.prepare("DELETE FROM refresh_tokens WHERE user_id = ?").bind(userId),
    // Export jobs (lib/export-job.ts): their files are under the prefix swept below, and a
    // step still running finds its row gone and deletes what it wrote.
    d1.prepare("DELETE FROM export_jobs WHERE user_id = ?").bind(userId),
  ]);
  const collect = async () => {
    // Every recorded key of the user, in or out of the prefix, once no upload can still be
    // writing it (an upload records its key before its put lands), then whatever the prefix
    // holds. A younger record is left for a later pass.
    await collectR2Garbage(db, env.TRACKS, {
      userId,
      before: now - UPLOAD_GRACE_MS,
      limit: Number.MAX_SAFE_INTEGER,
    });
    await deletePrefix(env.TRACKS, userPrefix(userId));
  };
  await collect();
  if (env.VOYAGE_LIVE) await purgeAccountVoyages(env as Env, userId);

  if (now - user.deletedAt < DELETION_GRACE_MS) {
    await db
      .update(users)
      .set({ deletionNextAt: user.deletedAt + DELETION_GRACE_MS })
      .where(eq(users.id, userId));
    return "pending";
  }
  // Last pass after the grace period: anything an in-flight request wrote has landed (and
  // was recorded) by now. The account record goes only once the user's ledger is empty, so
  // a late upload's record is collected (after its own grace) by a later pass, which then
  // sweeps the prefix again; never is a record consumed before its put can have landed.
  await collect();
  if (env.VOYAGE_LIVE) await purgeAccountVoyages(env as Env, userId);
  const [left] = await db
    .select({
      count: sql<number>`count(*)`,
      oldest: sql<number | null>`min(${pendingR2Deletes.createdAt})`,
    })
    .from(pendingR2Deletes)
    .where(eq(pendingR2Deletes.userId, userId));
  if ((left?.count ?? 0) > 0) {
    await db
      .update(users)
      .set({
        deletionNextAt: Math.max((left?.oldest ?? now) + UPLOAD_GRACE_MS + 1000, now + 60_000),
      })
      .where(eq(users.id, userId));
    return "pending";
  }
  await db.delete(users).where(and(eq(users.id, userId), isNotNull(users.deletedAt)));
  return "done";
}

/** Runs one pass and records the outcome for scheduling (backoff on failure). */
export async function runScheduledDeletion(
  env: DeletionEnv,
  userId: string,
  now = Date.now(),
): Promise<DeletionResult | "failed"> {
  try {
    return await runAccountDeletion(env, userId, now);
  } catch (error) {
    const [row] = await drizzle(env.DB)
      .update(users)
      .set({
        deletionAttempts: sql`${users.deletionAttempts} + 1`,
        deletionNextAt: sql`${now} + ${deletionBackoffMs(1)} * (1 << min(${users.deletionAttempts}, 9))`,
      })
      .where(eq(users.id, userId))
      .returning({ attempts: users.deletionAttempts });
    const attempts = row?.attempts ?? 0;
    if (attempts >= DELETION_ALERT_ATTEMPTS) {
      logFailure("account_deletion_failing", error);
    } else {
      logFailure("account_deletion_retry", error);
    }
    return "failed";
  }
}

/**
 * Scheduled: runs the deletions that are due, the longest-waiting first, so a deletion that
 * keeps failing backs off instead of blocking the others.
 */
export async function sweepAccountDeletions(
  env: DeletionEnv,
  now = Date.now(),
  limit = DELETION_SWEEP_LIMIT,
): Promise<{ done: number; pending: number; failed: number }> {
  const due = await drizzle(env.DB)
    .select({ id: users.id })
    .from(users)
    .where(
      and(
        isNotNull(users.deletedAt),
        or(isNull(users.deletionNextAt), lte(users.deletionNextAt, now)),
      ),
    )
    .orderBy(asc(sql`coalesce(${users.deletionNextAt}, 0)`), asc(users.deletedAt))
    .limit(limit);
  const counts = { done: 0, pending: 0, failed: 0 };
  for (const { id } of due) {
    const result = await runScheduledDeletion(env, id, now);
    if (result === "done") counts.done += 1;
    else if (result === "failed") counts.failed += 1;
    else counts.pending += 1;
  }
  return counts;
}

/** Whether a deleting account's grace period is over, so a pass would finish it. */
export const graceOver = (deletedAt: number, now = Date.now()) =>
  now - deletedAt >= DELETION_GRACE_MS;

/**
 * For a sign-in that met a deleting account: when its grace period is over, finishes the
 * deletion inline (no cron needed, e.g. on previews) and reports whether the Apple ID is
 * free again. Otherwise, or when the pass fails, the account stays reserved.
 */
export async function finishIfDue(env: DeletionEnv, error: AccountDeleting): Promise<boolean> {
  if (!error.userId || error.deletedAt === undefined || !graceOver(error.deletedAt)) return false;
  return (await runScheduledDeletion(env, error.userId)) === "done";
}

/**
 * Sign in with Apple for `sub`: finds or creates the account and issues its tokens. If the
 * account is being deleted and its grace period is over, finishes the deletion inline and
 * signs in again (a new, empty account). Throws AccountDeleting while the account is still
 * reserved, including when the deletion was requested between the lookup and the tokens.
 */
export async function signInAppleSubject<T>(
  env: DeletionEnv,
  sub: string,
  displayName: string | null,
  issue: (user: User) => Promise<T>,
): Promise<{ user: User; tokens: T }> {
  const db = drizzle(env.DB);
  for (let attempt = 0; ; attempt += 1) {
    try {
      const { user } = await findOrCreateUser(db, sub, displayName, {
        sharingEnabled: sharingAvailable(env),
      });
      return { user, tokens: await issue(user) };
    } catch (error) {
      if (error instanceof AccountDeleting && attempt === 0 && (await finishIfDue(env, error))) {
        continue;
      }
      throw error;
    }
  }
}
