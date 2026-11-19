import { and, eq, isNull } from "drizzle-orm";
import type { drizzle } from "drizzle-orm/d1";
import { type Session, sessions } from "../db/schema";
import { CLEARED_DERIVED } from "./postprocess";
import { userPrefix } from "./storage";

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

/** The upload revision a track object belongs to, from its key (`track.v1.gz` is 0). */
export function revisionOfTrackKey(key: string): number | null {
  const name = key.slice(key.lastIndexOf("/") + 1);
  if (name === "track.v1.gz") return 0;
  const match = /^track\.v1\.r(\d+)\.gz$/.exec(name);
  return match ? Number(match[1]) : null;
}

/**
 * Deletes the session's track objects for revisions below `revision`. The keys are derived
 * from the bucket listing, not remembered, so a delete that failed earlier is retried by
 * the next successful PUT for the session. Failures are left for that retry.
 */
export async function deleteOlderTracks(
  bucket: R2Bucket,
  userId: string,
  sessionId: string,
  revision: number,
): Promise<void> {
  try {
    const prefix = `${userPrefix(userId)}sessions/${sessionId}/`;
    let cursor: string | undefined;
    do {
      const page = await bucket.list({ prefix, cursor, limit: 1000 });
      const old = page.objects
        .map((o) => o.key)
        .filter((key) => {
          const keyRevision = revisionOfTrackKey(key);
          return keyRevision !== null && keyRevision < revision;
        });
      if (old.length > 0) await bucket.delete(old);
      cursor = page.truncated ? page.cursor : undefined;
    } while (cursor);
  } catch (error) {
    console.warn("Could not delete older session tracks; the next upload retries.", error);
  }
}

/**
 * Replaces the caller's metadata for an existing session with compare-and-swap on the
 * revision read:
 * - a lower revision than stored is stale;
 * - the same revision updates the fields and never touches the track;
 * - a strictly newer revision updates the fields and detaches the track, but only if the
 *   row is still at the revision read. Older track objects are deleted only after that.
 * A lost race re-reads and decides again. `hooks.afterRead` lets tests interleave.
 */
export async function replaceSessionMetadata(
  db: Db,
  bucket: R2Bucket,
  input: { id: string; userId: string; revision: number; fields: SessionFields },
  hooks: { afterRead?: () => Promise<void> } = {},
): Promise<ReplaceResult> {
  const { id, userId, revision, fields } = input;
  const own = and(eq(sessions.id, id), eq(sessions.userId, userId), isNull(sessions.deletedAt));
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const [current] = await db
      .select({ uploadRevision: sessions.uploadRevision })
      .from(sessions)
      .where(own);
    if (!current) return { kind: "missing" };
    if (current.uploadRevision > revision) return { kind: "stale", stored: current.uploadRevision };
    await hooks.afterRead?.();
    const newer = revision > current.uploadRevision;
    const [updated] = await db
      .update(sessions)
      .set({
        ...fields,
        uploadRevision: revision,
        // The derived data described the detached track (lib/postprocess.ts).
        ...(newer ? { trackKey: null, trackEtag: null, ...CLEARED_DERIVED } : {}),
        updatedAt: Date.now(),
      })
      .where(and(own, eq(sessions.uploadRevision, current.uploadRevision)))
      .returning();
    if (!updated) continue;
    await deleteOlderTracks(bucket, userId, id, revision);
    return { kind: "updated", session: updated };
  }
  const [now] = await db
    .select({ uploadRevision: sessions.uploadRevision })
    .from(sessions)
    .where(own);
  return now ? { kind: "stale", stored: now.uploadRevision } : { kind: "missing" };
}
