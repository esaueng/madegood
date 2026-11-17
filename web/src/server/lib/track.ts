/** Largest gzipped track the API stores: 8 MiB. A 10-hour session at 1 Hz is about 1 MiB. */
export const TRACK_MAX_BYTES = 8 * 1024 * 1024;

/**
 * Largest decompressed size a track may declare in its gzip trailer: 64 MiB. Whoever
 * decompresses a whole track must still enforce a limit while reading, because the trailer
 * only covers the last gzip member.
 */
export const TRACK_MAX_INFLATED_BYTES = 64 * 1024 * 1024;

/** The media type of an uploaded or downloaded track: the gzip file itself (docs/formats.md). */
export const TRACK_CONTENT_TYPE = "application/gzip";

/** Where a user's track for a session lives in the TRACKS bucket, under `userPrefix`. */
export const trackKey = (prefix: string, sessionId: string) =>
  `${prefix}sessions/${sessionId}/track.v1.gz`;

/** Reads a request body into memory, or returns null once it exceeds `limit` bytes. */
export async function readBody(
  body: ReadableStream<Uint8Array> | null,
  limit: number,
): Promise<Uint8Array | null> {
  if (!body) return new Uint8Array();
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

/**
 * Cheap checks that `bytes` looks like a gzipped track v1 file, without inflating it all:
 * the gzip header, the declared size in the trailer, and that the first inflated bytes
 * start a JSON object. Returns a reason when it does not.
 *
 * WaterKit writes keys sorted, so `v` and `sessionId` come after the GPS columns and
 * cannot be checked from a prefix. The post-processing consumer reads the whole file and
 * checks them (TODO in routes/sessions.ts).
 */
export async function checkTrack(bytes: Uint8Array): Promise<string | null> {
  // 10-byte header + 8-byte trailer; CM 8 is deflate, the only method gzip defines.
  if (bytes.byteLength < 18 || bytes[0] !== 0x1f || bytes[1] !== 0x8b || bytes[2] !== 8) {
    return "The body is not a gzip file.";
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const inflatedSize = view.getUint32(bytes.byteLength - 4, true);
  if (inflatedSize > TRACK_MAX_INFLATED_BYTES) {
    return `The track inflates to more than ${TRACK_MAX_INFLATED_BYTES} bytes.`;
  }

  const reader = new Blob([bytes])
    .stream()
    .pipeThrough(new DecompressionStream("gzip"))
    .getReader();
  let prefix = "";
  const decoder = new TextDecoder();
  try {
    // Inflate only until the first non-whitespace character, at most a few KiB.
    while (prefix.trimStart() === "" && prefix.length < 4096) {
      const { done, value } = await reader.read();
      if (done) break;
      prefix += decoder.decode(value.subarray(0, 4096), { stream: true });
    }
  } catch {
    return "The gzip data is corrupt.";
  } finally {
    reader.cancel().catch(() => {});
  }
  if (!prefix.trimStart().startsWith("{")) return "The track is not a JSON object.";
  return null;
}
