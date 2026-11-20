// The Open Graph preview card for a shared session (docs/PLAN.md §7): the route over a
// plain petrol-blue background with the sport, distance and duration, as an SVG that
// og/render.ts turns into a 1200 × 630 PNG. No map tiles: nothing here comes from a third
// party, and nothing needs attribution.
//
// Pure functions, no Worker APIs, so scripts/render-og.mjs can draw the same cards in Node.
// Text is limited to the sport names, digits and unit labels below (never the user's
// title), so the Latin subsets in og/fonts always have every glyph.

export const CARD_WIDTH = 1200;
export const CARD_HEIGHT = 630;

export const SPORT_NAMES = {
  sailing: "Sailing",
  windsurfing: "Windsurfing",
  motorboating: "Motorboating",
  kayak: "Kayak",
  canoe: "Canoe",
  sup: "Stand-up paddle",
} as const;
export type Sport = keyof typeof SPORT_NAMES;

export const UNITS = {
  nautical: { distance: 1 / 1852, distanceUnit: "nm", speed: 3600 / 1852, speedUnit: "kn" },
  metric: { distance: 1 / 1000, distanceUnit: "km", speed: 3.6, speedUnit: "km/h" },
  imperial: {
    distance: 1 / 1609.344,
    distanceUnit: "mi",
    speed: 3600 / 1609.344,
    speedUnit: "mph",
  },
} as const;
export type Units = keyof typeof UNITS;

/** "2 h 05 min" or "45 min". */
export function formatDuration(s: number): string {
  const total = Math.round(s);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  return h > 0 ? `${h} h ${String(m).padStart(2, "0")} min` : `${m} min`;
}

/** Distance in the user's unit, with fewer decimals as it grows: 3.25, 12.4, 128. */
export function formatDistance(meters: number, units: Units): { value: string; unit: string } {
  const u = UNITS[units];
  const d = meters * u.distance;
  const value = d < 10 ? d.toFixed(2) : d < 100 ? d.toFixed(1) : d.toFixed(0);
  return { value, unit: u.distanceUnit };
}

// ---- Palette (the petrol-blue brand of #83, assets/icon.svg) -------------------------

const PETROL_LIGHT = "#2387A6";
const PETROL = "#0B5470";
const PETROL_DEEP = "#04243A";
const BRIGHT_PETROL = "#4AAED4";
const PEARL = "#F4F5F2";
const MIST = "#9CC7D8"; // unit labels: pearl mixed into the background, still AA on it

const DISPLAY_FONT = "Inter Display";
const TEXT_FONT = "Inter";

/** The icon's swell glyph (assets/icon.svg), in its 1024-unit box. */
const SWELL =
  "M-111 770C-99 767 -57 767 -35 753C-13 739 3 714 21 685C38 655 52 620 70 576C87 531 104 464 125 419C146 374 168 335 195 305C222 276 255 248 286 243C316 238 349 253 376 275C403 297 425 337 446 374C467 410 486 465 502 494C517 522 525 546 536 546C548 546 554 521 571 494C589 467 618 412 641 385C664 357 687 342 711 330C734 318 755 309 780 314C806 318 841 329 864 357C887 385 901 434 920 480C938 526 959 595 975 633C991 671 1002 689 1017 709C1032 729 1045 743 1066 753C1087 763 1130 767 1142 770L1142 770C1124 770 1062 770 1031 770C1000 769 975 770 954 764C934 758 923 750 908 733C893 715 880 689 864 660C848 632 829 592 811 562C792 532 771 497 752 480C733 463 715 460 697 461C678 462 662 471 644 488C626 505 607 539 588 562C569 585 551 629 532 625C513 621 493 566 474 537C455 509 438 475 418 456C398 436 378 414 355 423C333 431 302 476 281 507C261 539 247 578 230 610C213 642 198 674 181 699C164 723 147 744 128 756C110 768 110 767 70 770C30 772 -81 770 -111 770Z";

const escapeXml = (text: string) =>
  text.replace(
    /[&<>"']/g,
    (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[ch] ?? ch,
  );

/** The app icon at `size` px with its top-left corner at (x, y). */
function logoMark(x: number, y: number, size: number): string {
  const s = size / 1024;
  return `<g transform="translate(${x} ${y}) scale(${s})">
  <clipPath id="logo-clip"><rect width="1024" height="1024" rx="228"/></clipPath>
  <g clip-path="url(#logo-clip)">
    <rect width="1024" height="1024" fill="url(#logo-bg)"/>
    <path d="${SWELL}" fill="url(#logo-glyph)"/>
  </g>
  <rect width="1024" height="1024" rx="228" fill="none" stroke="${PEARL}" stroke-opacity="0.18" stroke-width="${1.5 / s}"/>
</g>`;
}

/** Gradients, glow and the faint grid every card shares. */
function backdrop(glow: { cx: number; cy: number; r: number }, grid = true): string {
  return `<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="${PETROL}"/>
    <stop offset="0.6" stop-color="#073C55"/>
    <stop offset="1" stop-color="${PETROL_DEEP}"/>
  </linearGradient>
  <radialGradient id="glow" cx="${glow.cx}" cy="${glow.cy}" r="${glow.r}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#C7EEFF" stop-opacity="0.20"/>
    <stop offset="1" stop-color="#C7EEFF" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="logo-bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${PETROL_LIGHT}"/>
    <stop offset="0.55" stop-color="${PETROL}"/>
    <stop offset="1" stop-color="${PETROL_DEEP}"/>
  </linearGradient>
  <linearGradient id="logo-glyph" x1="0" y1="0.24" x2="0" y2="0.75">
    <stop offset="0" stop-color="#FFFFFF"/>
    <stop offset="0.5" stop-color="${PEARL}"/>
    <stop offset="1" stop-color="#DCDCD2"/>
  </linearGradient>
  <pattern id="grid" width="48" height="48" patternUnits="userSpaceOnUse">
    <path d="M48 0H0V48" fill="none" stroke="${PEARL}" stroke-opacity="0.07" stroke-width="1"/>
  </pattern>
  <linearGradient id="grid-fade" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#fff" stop-opacity="0"/>
    <stop offset="0.38" stop-color="#fff" stop-opacity="0"/>
    <stop offset="0.6" stop-color="#fff" stop-opacity="1"/>
  </linearGradient>
  <mask id="grid-mask"><rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#grid-fade)"/></mask>
  <filter id="route-glow" x="-10%" y="-10%" width="120%" height="120%">
    <feGaussianBlur stdDeviation="7"/>
  </filter>
</defs>
<rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#bg)"/>
<rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#glow)"/>
${grid ? `<rect width="${CARD_WIDTH}" height="${CARD_HEIGHT}" fill="url(#grid)" mask="url(#grid-mask)"/>` : ""}`;
}

const svgOpen = `<svg xmlns="http://www.w3.org/2000/svg" width="${CARD_WIDTH}" height="${CARD_HEIGHT}" viewBox="0 0 ${CARD_WIDTH} ${CARD_HEIGHT}">`;

// ---- Route geometry ------------------------------------------------------------------

export type LatLon = { lat: number; lon: number };

/** The box the route is fitted into, in card pixels. */
export const ROUTE_BOX = { x: 540, y: 64, width: 596, height: 502 } as const;
/** A route is drawn at least this many meters across, so GPS jitter at a mooring stays small. */
const MIN_SPAN_M = 300;
/** Points closer than this to the last kept one (card px) are dropped. */
const MIN_STEP_PX = 1.25;

const EARTH_RADIUS_M = 6_378_137;
const rad = (deg: number) => (deg * Math.PI) / 180;
const mercatorY = (lat: number) => Math.log(Math.tan(Math.PI / 4 + rad(lat) / 2));

/**
 * Splits shared GPS columns into the runs a viewer may draw: a new run starts at every
 * `gapIndex` (the shared track's privacyGap events), exactly where the website breaks its
 * line. Columns are those of a shared track (lib/session-privacy.ts), so fixes inside
 * privacy zones are already gone.
 */
export function routeRuns(
  lat: readonly number[],
  lon: readonly number[],
  gapIndexes: Iterable<number>,
): LatLon[][] {
  const breaks = new Set(gapIndexes);
  const runs: LatLon[][] = [];
  let run: LatLon[] = [];
  const n = Math.min(lat.length, lon.length);
  for (let i = 0; i < n; i++) {
    if (breaks.has(i) && run.length > 0) {
      runs.push(run);
      run = [];
    }
    run.push({ lat: lat[i] as number, lon: lon[i] as number });
  }
  if (run.length > 0) runs.push(run);
  return runs;
}

export type ProjectedRoute = {
  /** Polylines in card pixels, decimated; single-point runs have one point. */
  runs: [number, number][][];
  start: [number, number] | null;
  end: [number, number] | null;
};

/**
 * Web Mercator projection of `runs`, north up, fitted and centered in `box`. Longitudes
 * are unwrapped from the first fix, so a route across the antimeridian stays in one piece.
 */
export function projectRoute(
  runs: readonly (readonly LatLon[])[],
  box: { x: number; y: number; width: number; height: number } = ROUTE_BOX,
): ProjectedRoute {
  const raw: [number, number][][] = [];
  let reference: number | null = null;
  let previousLon = 0;
  let unwrapped = 0;
  let [minX, minY, maxX, maxY] = [Infinity, Infinity, -Infinity, -Infinity];
  let latSum = 0;
  let count = 0;
  for (const run of runs) {
    const out: [number, number][] = [];
    for (const p of run) {
      if (reference === null) {
        reference = p.lon;
        unwrapped = p.lon;
      } else {
        unwrapped += ((((p.lon - previousLon) % 360) + 540) % 360) - 180;
      }
      previousLon = p.lon;
      const x = rad(unwrapped);
      const y = -mercatorY(p.lat);
      out.push([x, y]);
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);
      latSum += p.lat;
      count++;
    }
    if (out.length > 0) raw.push(out);
  }
  if (count === 0) return { runs: [], start: null, end: null };

  // Mercator units per meter at the route's mean latitude, for the minimum span.
  const perMeter = 1 / (EARTH_RADIUS_M * Math.cos(rad(latSum / count)));
  const minSpan = MIN_SPAN_M * perMeter;
  const spanX = Math.max(maxX - minX, minSpan);
  const spanY = Math.max(maxY - minY, minSpan);
  const scale = Math.min(box.width / spanX, box.height / spanY);
  const cx = (minX + maxX) / 2;
  const cy = (minY + maxY) / 2;
  const toPx = ([x, y]: [number, number]): [number, number] => [
    box.x + box.width / 2 + (x - cx) * scale,
    box.y + box.height / 2 + (y - cy) * scale,
  ];

  const projected: [number, number][][] = [];
  for (const run of raw) {
    const px = run.map(toPx);
    const kept: [number, number][] = [px[0] as [number, number]];
    for (let i = 1; i < px.length; i++) {
      const p = px[i] as [number, number];
      const last = kept[kept.length - 1] as [number, number];
      if (Math.hypot(p[0] - last[0], p[1] - last[1]) >= MIN_STEP_PX || i === px.length - 1) {
        kept.push(p);
      }
    }
    projected.push(kept);
  }
  const firstRun = projected[0] as [number, number][];
  const lastRun = projected[projected.length - 1] as [number, number][];
  return {
    runs: projected,
    start: firstRun[0] ?? null,
    end: lastRun[lastRun.length - 1] ?? null,
  };
}

const r1 = (n: number) => Math.round(n * 10) / 10;

function pathData(runs: [number, number][][]): string {
  return runs
    .filter((run) => run.length > 1)
    .map((run) => run.map(([x, y], i) => `${i === 0 ? "M" : "L"}${r1(x)} ${r1(y)}`).join(""))
    .join("");
}

// ---- Cards ---------------------------------------------------------------------------

export type RouteCard = {
  sport: Sport;
  units: Units;
  distanceM: number | null;
  durationS: number | null;
  route: ProjectedRoute;
};

/** Alt text for a route card, matching what it shows. */
export function routeCardAlt(card: Omit<RouteCard, "route">): string {
  const parts: string[] = [];
  if (card.distanceM != null) {
    const d = formatDistance(card.distanceM, card.units);
    parts.push(`${d.value} ${d.unit}`);
  }
  if (card.durationS != null) parts.push(`in ${formatDuration(card.durationS)}`);
  const sport = SPORT_NAMES[card.sport].toLowerCase();
  return `Route map of a ${sport} session${parts.length > 0 ? `: ${parts.join(" ")}` : ""}`;
}

/** Unit-suffixed durations: "2 h 05 min" with the numbers large and the units small. */
function durationTspans(s: number, size: number): string {
  const unit = (text: string) =>
    `<tspan font-family="${TEXT_FONT}" font-weight="500" font-size="${Math.round(size * 0.48)}" fill="${MIST}">${text}</tspan>`;
  const total = Math.round(s);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
  return h > 0
    ? `${h}<tspan dx="10">${unit("h")}</tspan><tspan dx="18">${mm}</tspan><tspan dx="10">${unit("min")}</tspan>`
    : `${mm}<tspan dx="10">${unit("min")}</tspan>`;
}

export function routeCardSvg(card: RouteCard): string {
  const { route } = card;
  const path = pathData(route.runs);
  const dots = route.runs
    .filter((run) => run.length === 1)
    .map(
      ([p]) =>
        `<circle cx="${r1((p as number[])[0] as number)}" cy="${r1((p as number[])[1] as number)}" r="4" fill="${PEARL}"/>`,
    )
    .join("");
  const routeSvg = `<g fill="none" stroke-linecap="round" stroke-linejoin="round">
  <path d="${path}" stroke="${BRIGHT_PETROL}" stroke-opacity="0.55" stroke-width="16" filter="url(#route-glow)"/>
  <path d="${path}" stroke="${PETROL_DEEP}" stroke-opacity="0.45" stroke-width="11"/>
  <path d="${path}" stroke="${PEARL}" stroke-width="6"/>
</g>${dots}${
    route.start
      ? `<circle cx="${r1(route.start[0])}" cy="${r1(route.start[1])}" r="10" fill="${PETROL_DEEP}" stroke="${BRIGHT_PETROL}" stroke-width="5"/>`
      : ""
  }${
    route.end
      ? `<circle cx="${r1(route.end[0])}" cy="${r1(route.end[1])}" r="11" fill="${PEARL}" stroke="${PETROL_DEEP}" stroke-width="4"/>`
      : ""
  }`;

  const left = 76;
  const rows: string[] = [];
  let y = 268;
  rows.push(
    `<text x="${left}" y="${y}" font-family="${TEXT_FONT}" font-weight="500" font-size="28" letter-spacing="4" fill="${BRIGHT_PETROL}">${escapeXml(SPORT_NAMES[card.sport].toUpperCase())}</text>`,
  );
  if (card.distanceM != null) {
    const d = formatDistance(card.distanceM, card.units);
    y += 112;
    rows.push(
      `<text x="${left - 4}" y="${y}" font-family="${DISPLAY_FONT}" font-weight="600" font-size="112" fill="${PEARL}">${d.value}<tspan dx="14" font-family="${TEXT_FONT}" font-weight="500" font-size="44" fill="${MIST}">${d.unit}</tspan></text>`,
    );
  }
  if (card.durationS != null) {
    y += card.distanceM != null ? 100 : 112;
    const size = card.distanceM != null ? 76 : 112;
    rows.push(
      `<text x="${left - 3}" y="${y}" font-family="${DISPLAY_FONT}" font-weight="600" font-size="${size}" fill="${PEARL}">${durationTspans(card.durationS, size)}</text>`,
    );
  }

  return `${svgOpen}
${backdrop({ cx: ROUTE_BOX.x + ROUTE_BOX.width / 2, cy: 140, r: 560 })}
${routeSvg}
${logoMark(left, 64, 60)}
<text x="${left + 80}" y="105" font-family="${DISPLAY_FONT}" font-weight="600" font-size="34" fill="${PEARL}">MadeGood</text>
${rows.join("\n")}
</svg>`;
}

export const BRAND_CARD_ALT = "MadeGood: open-source tracking for time on the water";

/** The card for sessions without a route image, and for the site itself. */
export function brandCardSvg(): string {
  const swellScale = 1.6;
  return `${svgOpen}
${backdrop({ cx: CARD_WIDTH / 2, cy: 120, r: 640 }, false)}
<g transform="translate(${CARD_WIDTH / 2 - (1024 * swellScale) / 2} ${CARD_HEIGHT - 770 * swellScale + 150}) scale(${swellScale})">
  <path d="${SWELL}" fill="${PEARL}" fill-opacity="0.035"/>
</g>
${logoMark(CARD_WIDTH / 2 - 72, 128, 144)}
<text x="${CARD_WIDTH / 2}" y="388" text-anchor="middle" font-family="${DISPLAY_FONT}" font-weight="600" font-size="84" fill="${PEARL}">MadeGood</text>
<text x="${CARD_WIDTH / 2}" y="452" text-anchor="middle" font-family="${TEXT_FONT}" font-weight="500" font-size="32" fill="${MIST}">Open-source tracking for sailing, paddling and time on the water</text>
</svg>`;
}
