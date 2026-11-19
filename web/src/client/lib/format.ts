import type { Sport, Units } from "./api";

// Values arrive in SI (m, s, m/s); convert only for display (AGENTS.md). The exact
// definitions match WaterKit: 1 nm = 1852 m, 1 mi = 1609.344 m.

const SPEED: Record<Units, { factor: number; unit: string }> = {
  nautical: { factor: 3600 / 1852, unit: "kn" },
  metric: { factor: 3.6, unit: "km/h" },
  imperial: { factor: 3600 / 1609.344, unit: "mph" },
};

const DISTANCE: Record<Units, { factor: number; unit: string }> = {
  nautical: { factor: 1 / 1852, unit: "nm" },
  metric: { factor: 1 / 1000, unit: "km" },
  imperial: { factor: 1 / 1609.344, unit: "mi" },
};

export const speedUnit = (units: Units) => SPEED[units].unit;
export const toSpeed = (mps: number, units: Units) => mps * SPEED[units].factor;

export function formatSpeed(mps: number | null | undefined, units: Units): string {
  if (mps == null || !Number.isFinite(mps)) return "–";
  return `${toSpeed(mps, units).toFixed(1)} ${speedUnit(units)}`;
}

export function formatDistance(m: number | null | undefined, units: Units): string {
  if (m == null || !Number.isFinite(m)) return "–";
  const { factor, unit } = DISTANCE[units];
  const value = m * factor;
  return `${value.toFixed(value < 10 ? 2 : 1)} ${unit}`;
}

export function formatDuration(s: number | null | undefined): string {
  if (s == null || !Number.isFinite(s)) return "–";
  const total = Math.round(s);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const sec = total % 60;
  const mm = String(m).padStart(2, "0");
  const ss = String(sec).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}

export const SPORT_NAMES: Record<Sport, string> = {
  sailing: "Sailing",
  windsurfing: "Windsurfing",
  motorboating: "Motorboating",
  kayak: "Kayak",
  canoe: "Canoe",
  sup: "Stand-up paddle",
};

export function formatDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

export const sessionTitle = (session: { title: string | null; sport: Sport }) =>
  session.title ?? SPORT_NAMES[session.sport];
