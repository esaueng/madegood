export type VoyageKey = { userId: string; voyageId: string };

export function liveVoyage(env: Env, { userId, voyageId }: VoyageKey) {
  if (!env.VOYAGE_LIVE) throw new Error("Voyage live storage is unavailable.");
  return env.VOYAGE_LIVE.getByName(JSON.stringify([userId, voyageId]));
}

export async function locateShare(db: D1Database, slugHash: string): Promise<VoyageKey | null> {
  return db
    .prepare(
      `SELECT r.user_id AS userId, r.voyage_id AS voyageId
       FROM voyage_live_registry r JOIN voyages v ON v.user_id = r.user_id AND v.id = r.voyage_id
       JOIN users u ON u.id = r.user_id
       WHERE r.slug_hash = ? AND v.ended_at IS NULL AND u.deleted_at IS NULL
         AND u.sharing_enabled = 1`,
    )
    .bind(slugHash)
    .first<VoyageKey>();
}

export async function purgeAccountVoyages(env: Env, userId: string): Promise<void> {
  // D1 has already deleted the user. Registration requires an existing active voyage.
  const { results } = await env.DB.prepare(
    "SELECT voyage_id AS voyageId FROM voyage_live_registry WHERE user_id = ?",
  )
    .bind(userId)
    .all<{ voyageId: string }>();
  for (const { voyageId } of results) {
    await liveVoyage(env, { userId, voyageId }).purge();
    await env.DB.prepare("DELETE FROM voyage_live_registry WHERE user_id = ? AND voyage_id = ?")
      .bind(userId, voyageId)
      .run();
  }
}
