import { describe, expect, it } from "vitest";
import {
  type Fix,
  fixIndexAt,
  parseTrack,
  positionAt,
  segmentsOf,
  speedLines,
  speedScaleMax,
  thin,
} from "../src/client/lib/track";

// The session page's track helpers (src/client/lib/track.ts). Synthetic positions near 0,0.

const fix = (t: number, spd: number | null = 1): Fix => ({ t, lat: t * 1e-5, lon: 0, spd });

describe("parseTrack", () => {
  it("keeps valid fixes sorted by time and rejects other versions", () => {
    const track = parseTrack({
      v: 1,
      startedAt: "2000-01-01T00:00:00.000Z",
      gps: {
        t: [2, 0, 1, 3],
        lat: [0.00002, 0, 0.00001, 95],
        lon: [0, 0, 0, 0],
        spd: [1, null, -1, 1],
      },
      hr: { t: [0.5, 1], bpm: [90, 0] },
      events: [{ t: 1, type: "tack" }, { type: "broken" }],
    });
    expect(track.fixes.map((f) => [f.t, f.spd])).toEqual([
      [0, null],
      [1, null],
      [2, 1],
    ]);
    expect(track.hr).toEqual([{ t: 0.5, bpm: 90 }]);
    expect(track.events).toEqual([{ t: 1, type: "tack" }]);
    expect(track.endT).toBe(2);
    expect(() => parseTrack({ v: 2 })).toThrow();
  });
});

describe("segmentsOf", () => {
  it("splits at gaps over 30 s and after a resume that follows a pause", () => {
    const fixes = [0, 1, 2, 40, 41, 42, 43].map((t) => fix(t));
    expect(segmentsOf(fixes, [])).toEqual([
      [0, 3],
      [3, 7],
    ]);
    const events = [
      { t: 41.5, type: "pause" },
      { t: 42.5, type: "resume" },
      // A resume without a pause splits nothing.
      { t: 0.5, type: "resume" },
    ];
    expect(segmentsOf(fixes, events)).toEqual([
      [0, 3],
      [3, 6],
      [6, 7],
    ]);
  });
});

describe("replay lookups", () => {
  const track = parseTrack({
    v: 1,
    gps: { t: [0, 10, 100], lat: [0, 0.0001, 0.0002], lon: [0, 0, 0], spd: [1, 3, 2] },
    events: [],
  });

  it("interpolates position and speed inside a segment, nothing in a gap", () => {
    expect(fixIndexAt(track.fixes, -1)).toBe(-1);
    expect(fixIndexAt(track.fixes, 10)).toBe(1);
    const mid = positionAt(track, 5);
    expect(mid?.lat).toBeCloseTo(0.00005);
    expect(mid?.spd).toBeCloseTo(2);
    expect(positionAt(track, 50)).toBeNull();
    expect(positionAt(track, 100)?.lat).toBe(0.0002);
  });
});

describe("speedLines", () => {
  it("merges runs in the same speed bin and never joins segments", () => {
    const track = parseTrack({
      v: 1,
      gps: {
        t: [0, 1, 2, 3, 100, 101],
        lat: [0, 0.00001, 0.00002, 0.00003, 0.001, 0.00101],
        lon: [0, 0, 0, 0, 0, 0],
        spd: [1, 1, 1, 4, 1, 1],
      },
      events: [],
    });
    const max = speedScaleMax(track.fixes);
    expect(max).toBe(4);
    const lines = speedLines(track, max);
    expect(lines.features.map((f) => [f.properties.bin, f.geometry.coordinates.length])).toEqual([
      [2, 3],
      [5, 2],
      [2, 2],
    ]);
  });
});

describe("thin", () => {
  it("keeps short series and the last point of long ones", () => {
    expect(thin([1, 2, 3], 5)).toEqual([1, 2, 3]);
    const out = thin(
      Array.from({ length: 1000 }, (_, i) => i),
      10,
    );
    expect(out.length).toBeLessThanOrEqual(11);
    expect(out.at(-1)).toBe(999);
  });
});
