#!/usr/bin/env node
// Draws the Open Graph cards (src/server/og/card.ts) in Node with the same renderer and
// fonts as the Worker.
//
//   node scripts/render-og.mjs            writes public/og-default.png (the brand card)
//   node scripts/render-og.mjs <dir>      also writes sample route cards into <dir>
//
// Samples use synthetic tracks near 0,0 only (AGENTS.md: never real coordinates).
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { initWasm, Resvg } from "@resvg/resvg-wasm";
import { createServer } from "vite";

const web = path.resolve(import.meta.dirname, "..");
const server = await createServer({
  root: web,
  configFile: false,
  logLevel: "error",
  server: { middlewareMode: true, hmr: false },
  appType: "custom",
});

try {
  const card = await server.ssrLoadModule("/src/server/og/card.ts");
  const privacy = await server.ssrLoadModule("/src/server/lib/session-privacy.ts");

  await initWasm(await readFile(path.join(web, "node_modules/@resvg/resvg-wasm/index_bg.wasm")));
  const fontBuffers = await Promise.all(
    ["inter-display-semibold.latin.ttf.bin", "inter-medium.latin.ttf.bin"].map((name) =>
      readFile(path.join(web, "src/server/og/fonts", name)),
    ),
  );
  const png = (svg) => {
    const resvg = new Resvg(svg, {
      font: { fontBuffers, defaultFontFamily: "Inter" },
      shapeRendering: 2,
      textRendering: 1,
    });
    return resvg.render().asPng();
  };

  await writeFile(path.join(web, "public/og-default.png"), png(card.brandCardSvg()));
  console.log("public/og-default.png");

  const out = process.argv[2];
  if (out) {
    for (const sample of samples()) {
      const shared = privacy.shareTrack(sample.track, sample.zones ?? [], null);
      const gaps = shared.events
        .filter((e) => e.type === privacy.PRIVACY_GAP_EVENT)
        .map((e) => e.data.index);
      const route = card.projectRoute(card.routeRuns(shared.gps.lat, shared.gps.lon, gaps));
      const file = path.join(out, `${sample.name}.png`);
      await writeFile(file, png(card.routeCardSvg({ ...sample.card, route })));
      console.log(file);
    }
  }
} finally {
  await server.close();
}

/** Synthetic tracks: a few shapes near 0,0, in degrees (1e-5° ≈ 1.1 m). */
function samples() {
  const M = 1 / 111_195;
  const toTrack = (points) => ({
    v: 1,
    sessionId: "00000000-0000-4000-8000-000000000000",
    startedAt: "2000-01-01T10:00:00.000Z",
    gps: {
      t: points.map((_, i) => i),
      lat: points.map((p) => p[1] * M),
      lon: points.map((p) => p[0] * M),
    },
    events: [],
  });
  // Deterministic jitter.
  let seed = 7;
  const noise = (amp) => {
    seed = (seed * 16807) % 2147483647;
    return ((seed / 2147483647) * 2 - 1) * amp;
  };

  // Windward-leeward race: tacks up a 2 km beat, a run back down, twice.
  const race = [];
  let [x, y] = [0, 0];
  for (let lap = 0; lap < 2; lap++) {
    for (let leg = 0; leg < 7; leg++) {
      const dir = leg % 2 === 0 ? 1 : -1;
      for (let i = 0; i < 60; i++) {
        x += dir * 4.5 + noise(0.6);
        y += 5 + noise(0.6);
        race.push([x, y]);
      }
    }
    for (let i = 0; i < 200; i++) {
      x += Math.sin(i / 25) * 3 - x / 200;
      y -= 10.5 + noise(0.8);
      race.push([x, y]);
    }
  }

  // Paddle round an island, starting and ending at a launch inside a privacy zone.
  const loop = [];
  for (let i = 0; i <= 900; i++) {
    const a = (i / 900) * Math.PI * 2;
    const r = 900 + 220 * Math.sin(3 * a) + 90 * Math.cos(5 * a + 1) + noise(4);
    loop.push([r * Math.cos(a) * 1.3, r * Math.sin(a)]);
  }

  // A short stand-up paddle out and back along a shore.
  const sup = [];
  for (let i = 0; i <= 400; i++) {
    const s = i < 200 ? i : 400 - i;
    sup.push([s * 6, 60 * Math.sin(s / 30) + (i < 200 ? 0 : 25) + noise(2)]);
  }

  // A long motorboat passage with a dogleg.
  const passage = [];
  for (let i = 0; i <= 600; i++) {
    const t = i / 600;
    passage.push([
      t * 60_000 + 6000 * Math.sin(t * Math.PI),
      t < 0.55 ? t * 20_000 : 11_000 + (t - 0.55) * 60_000,
    ]);
  }

  return [
    {
      name: "sailing-race",
      track: toTrack(race),
      card: { sport: "sailing", units: "nautical", distanceM: 13_420, durationS: 7_510 },
    },
    {
      name: "kayak-island-zone",
      track: toTrack(loop),
      zones: [{ lat: 0, lon: 1170 * M, radiusM: 250 }],
      card: { sport: "kayak", units: "metric", distanceM: 6_840, durationS: 5_400 },
    },
    {
      name: "sup-short-imperial",
      track: toTrack(sup),
      card: { sport: "sup", units: "imperial", distanceM: 2_430, durationS: 2_880 },
    },
    {
      name: "motorboat-passage",
      track: toTrack(passage),
      card: { sport: "motorboating", units: "nautical", distanceM: 71_200, durationS: 14_100 },
    },
    {
      name: "windsurfing-no-duration",
      track: toTrack(race.slice(0, 400)),
      card: { sport: "windsurfing", units: "metric", distanceM: 4_150, durationS: null },
    },
  ];
}
