// Kept apart from the map so pages (and tests) can use these without loading MapLibre.

/** Slow to fast: blue, teal, green, yellow, orange, red. Readable on light map tiles. */
export const SPEED_COLORS = [
  "#2c5fd1",
  "#1f8fc4",
  "#18a39a",
  "#43a845",
  "#a3b81c",
  "#e0a800",
  "#e8650f",
  "#d42a20",
];

/**
 * Options for the track's GeoJSON source. MapLibre simplifies lines by default (0.375 px),
 * which at low zoom can draw a small detour as a shortcut through a privacy zone the server
 * checked fix by fix. Anyone but the owner sees the line exactly as served.
 */
export const trackSourceOptions = (isOwner: boolean): { tolerance?: number } =>
  isOwner ? {} : { tolerance: 0 };
