// A minimal streaming ZIP writer (PKWARE APPNOTE 6.3): stored entries only, no compression
// (the track files are already gzip), sizes and CRC-32 in a data descriptor after each
// entry, so an entry's bytes pass straight through without being buffered. No ZIP64: the
// caller keeps the archive under 4 GiB and 65,535 entries (`ZIP_MAX_BYTES`, `ZIP_MAX_ENTRIES`).

export const ZIP_MAX_ENTRIES = 65_535;
export const ZIP_MAX_BYTES = 0xffff_ffff;

export type ZipEntry = {
  /** Path inside the archive, `/`-separated, no leading slash. */
  name: string;
  /** The entry's bytes, read once. */
  data: () => Promise<Uint8Array | ReadableStream<Uint8Array> | null>;
};

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

/** Updates a running CRC-32; start with `0xffffffff`, finish with `~crc >>> 0`. */
export function crc32Update(crc: number, bytes: Uint8Array): number {
  let c = crc;
  for (let i = 0; i < bytes.length; i++)
    c = (CRC_TABLE[(c ^ (bytes[i] ?? 0)) & 0xff] ?? 0) ^ (c >>> 8);
  return c >>> 0;
}

export const crc32 = (bytes: Uint8Array) => ~crc32Update(0xffffffff, bytes) >>> 0;

/** MS-DOS date and time fields (UTC; ZIP has no time zone). */
function dosDateTime(date: Date): { time: number; date: number } {
  const year = Math.min(Math.max(date.getUTCFullYear(), 1980), 2107);
  return {
    time: (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | (date.getUTCSeconds() >> 1),
    date: ((year - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate(),
  };
}

// Bit 3: sizes and CRC follow in a data descriptor. Bit 11: names are UTF-8.
const FLAGS = 0x0808;
const VERSION = 20;

class Bytes {
  private readonly view: DataView;
  readonly array: Uint8Array;
  private offset = 0;
  constructor(size: number) {
    this.array = new Uint8Array(size);
    this.view = new DataView(this.array.buffer);
  }
  u16(value: number) {
    this.view.setUint16(this.offset, value, true);
    this.offset += 2;
    return this;
  }
  u32(value: number) {
    this.view.setUint32(this.offset, value >>> 0, true);
    this.offset += 4;
    return this;
  }
  bytes(value: Uint8Array) {
    this.array.set(value, this.offset);
    this.offset += value.length;
    return this;
  }
}

type Written = { name: Uint8Array; crc: number; size: number; offset: number };

/**
 * Yields the archive's bytes entry by entry. An entry whose `data` resolves to null (for
 * example a track deleted since the export started) is left out.
 */
export async function* zipStream(
  entries: Iterable<ZipEntry> | AsyncIterable<ZipEntry>,
  modified: Date,
): AsyncGenerator<Uint8Array> {
  const { time, date } = dosDateTime(modified);
  const encoder = new TextEncoder();
  const written: Written[] = [];
  let offset = 0;

  for await (const entry of entries) {
    if (written.length >= ZIP_MAX_ENTRIES) throw new Error("too many ZIP entries");
    const source = await entry.data();
    if (source === null) continue;
    const name = encoder.encode(entry.name);
    const header = new Bytes(30 + name.length)
      .u32(0x04034b50)
      .u16(VERSION)
      .u16(FLAGS)
      .u16(0) // stored
      .u16(time)
      .u16(date)
      .u32(0)
      .u32(0)
      .u32(0)
      .u16(name.length)
      .u16(0)
      .bytes(name).array;
    const start = offset;
    yield header;
    offset += header.length;

    let crc = 0xffffffff;
    let size = 0;
    if (source instanceof Uint8Array) {
      crc = crc32Update(crc, source);
      size = source.length;
      if (size > 0) yield source;
    } else {
      const reader = source.getReader();
      let finished = false;
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          crc = crc32Update(crc, value);
          size += value.length;
          yield value;
        }
        finished = true;
      } finally {
        // A client that went away stops the R2 read too.
        if (!finished) await reader.cancel().catch(() => {});
        reader.releaseLock();
      }
    }
    offset += size;
    crc = ~crc >>> 0;
    if (offset + 16 > ZIP_MAX_BYTES) throw new Error("ZIP archive too large");
    const descriptor = new Bytes(16).u32(0x08074b50).u32(crc).u32(size).u32(size).array;
    yield descriptor;
    offset += descriptor.length;
    written.push({ name, crc, size, offset: start });
  }

  const directoryStart = offset;
  for (const entry of written) {
    const record = new Bytes(46 + entry.name.length)
      .u32(0x02014b50)
      .u16(VERSION)
      .u16(VERSION)
      .u16(FLAGS)
      .u16(0)
      .u16(time)
      .u16(date)
      .u32(entry.crc)
      .u32(entry.size)
      .u32(entry.size)
      .u16(entry.name.length)
      .u16(0)
      .u16(0)
      .u16(0)
      .u16(0)
      .u32(0)
      .u32(entry.offset)
      .bytes(entry.name).array;
    yield record;
    offset += record.length;
  }
  if (offset + 22 > ZIP_MAX_BYTES) throw new Error("ZIP archive too large");
  yield new Bytes(22)
    .u32(0x06054b50)
    .u16(0)
    .u16(0)
    .u16(written.length)
    .u16(written.length)
    .u32(offset - directoryStart)
    .u32(directoryStart)
    .u16(0).array;
}

/** A pull-based stream over `zipStream`: it reads the next entry only when the client does. */
export function zipResponseBody(
  entries: Iterable<ZipEntry> | AsyncIterable<ZipEntry>,
  modified: Date,
): ReadableStream<Uint8Array> {
  const chunks = zipStream(entries, modified);
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const { done, value } = await chunks.next();
        if (done) controller.close();
        else controller.enqueue(value);
      } catch (err) {
        // A truncated archive fails to open, which is the right signal for a broken export.
        console.error(err);
        controller.error(err);
      }
    },
    async cancel() {
      await chunks.return(undefined);
    },
  });
}
