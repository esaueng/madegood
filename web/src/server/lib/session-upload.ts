import { and, eq, isNull } from "drizzle-orm";
import type { drizzle } from "drizzle-orm/d1";
import { type Session, sessions } from "../db/schema";
import { CLEARED_DERIVED } from "./postprocess";
import { userPrefix } from "./storage";
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

export type StoreResult =
  | { kind: "attached"; etag: string; httpEtag: string }
  | { kind: "detached" };

/**
 * Stores a track object and attaches it to the row while the row is still at `revision`,
 * clearing the data derived from an earlier upload. Returns the ETag the row records,
 * which is always the ETag of the object R2 holds once this returns.
 *
 * Two uploads of the same revision with different bytes can interleave so that R2 keeps
 * B's bytes while the row records A's ETag (A attached last). Each upload therefore reads
 * the object back after attaching and, when it differs, moves the row to the stored ETag
 * (compare-and-swap on the ETag it wrote). The last upload to attach always does this
 * after the last put, so the row ends at the stored object. `hooks` let tests interleave.
 */
export async function storeTrack(
  db: Db,
  bucket: R2Bucket,
  input: { id: string; userId: string; revision: number; key: string; bytes: Uint8Array },
  hooks: { afterPut?: () => Promise<void> } = {},
): Promise<StoreResult> {
  const { id, userId, revision, key, bytes } = input;
  const object = await bucket.put(key, bytes, {
    httpMetadata: { contentType: TRACK_CONTENT_TYPE },
  });
  await hooks.afterPut?.();
  const atRevision = and(
    eq(sessions.id, id),
    eq(sessions.userId, userId),
    isNull(sessions.deletedAt),
    eq(sessions.uploadRevision, revision),
  );
  const [attached] = await db
    .update(sessions)
    .set({ trackKey: key, trackEtag: object.etag, ...CLEARED_DERIVED, updatedAt: Date.now() })
    .where(atRevision)
    .returning({ id: sessions.id });
  if (!attached) return { kind: "detached" };

  let etag = object.etag;
  let httpEtag = object.httpEtag;
  for (let attempt = 0; attempt < 5; attempt++) {
    const stored = await bucket.head(key);
    if (!stored || stored.etag === etag) break;
    const [moved] = await db
      .update(sessions)
      .set({ trackEtag: stored.etag, ...CLEARED_DERIVED, updatedAt: Date.now() })
      .where(and(atRevision, eq(sessions.trackKey, key), eq(sessions.trackEtag, etag)))
      .returning({ id: sessions.id });
    // Another upload attached after this one; it reads the object back itself.
    if (!moved) break;
    etag = stored.etag;
    httpEtag = stored.httpEtag;
  }
  return { kind: "attached", etag, httpEtag };
}
