import { z } from "@hono/zod-openapi";

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
export const TRACK_SPORTS = [
  "sailing",
  "windsurfing",
  "motorboating",
  "kayak",
  "canoe",
  "sup",
] as const;

/** Bound memory for the private leg endpoint, which validates the complete JSON. */
const LEG_TRACK_MAX_INFLATED_BYTES = 16 * 1024 * 1024;

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

const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const finite = (value: unknown) => typeof value === "number" && Number.isFinite(value);
const trackDate = z.iso.datetime({ offset: true });

function trackColumns(
  value: unknown,
  numbers: string[],
  nullable: string[] = [],
  optional: string[] = [],
) {
  if (!record(value) || !Array.isArray(value.t)) return false;
  const count = value.t.length;
  function column(key: string, allowNull: boolean) {
    const items = valueRecord[key];
    return (
      Array.isArray(items) &&
      items.length === count &&
      items.every((item) => (allowNull && item === null) || finite(item))
    );
  }
  const valueRecord = value;
  return (
    numbers.every((key) => column(key, false)) &&
    nullable.every((key) => column(key, true)) &&
    optional.every((key) => value[key] == null || column(key, true))
  );
}

/** Check a completed leg's complete track before allocating its immutable R2 key. */
export async function checkLegTrack(bytes: Uint8Array, legId: string): Promise<string | null> {
  const structure = await checkTrack(bytes);
  if (structure) return structure;
  try {
    const inflated = await readBody(
      new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip")),
      LEG_TRACK_MAX_INFLATED_BYTES,
    );
    if (!inflated) return "The private leg track inflates to more than 16 MiB.";
    const track: unknown = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(inflated),
    );
    if (!record(track) || track.v !== 1) return "The body must be a track v1 document.";
    if (typeof track.sessionId !== "string" || track.sessionId.toLowerCase() !== legId) {
      return "The track sessionId must match the leg UUID.";
    }
    if (
      !TRACK_SPORTS.some((sport) => sport === track.sport) ||
      !trackDate.safeParse(track.startedAt).success ||
      !trackColumns(
        track.gps,
        ["t", "lat", "lon"],
        ["spd", "crs", "hacc"],
        ["alt", "spdacc", "crsacc"],
      ) ||
      !trackColumns(track.hr, ["t", "bpm"]) ||
      !Array.isArray(track.events) ||
      !track.events.every(
        (event) =>
          record(event) &&
          finite(event.t) &&
          typeof event.type === "string" &&
          (event.data == null || record(event.data)),
      ) ||
      (track.analyzerVersion != null && typeof track.analyzerVersion !== "string")
    ) {
      return "The track v1 fields or sample columns are invalid.";
    }
    return null;
  } catch {
    return "The gzip file does not contain valid track JSON.";
  }
}
