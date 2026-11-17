/**
 * Every R2 object that belongs to a user lives under this prefix in the TRACKS bucket, so
 * deleting an account can remove them all by listing it. Upload code must use it.
 */
export const userPrefix = (userId: string) => `users/${userId}/`;

/** Deletes every object under `prefix`. Safe to repeat. */
export async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<number> {
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor, limit: 1000 });
    const keys = page.objects.map((o) => o.key);
    if (keys.length > 0) {
      await bucket.delete(keys);
      deleted += keys.length;
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return deleted;
}
