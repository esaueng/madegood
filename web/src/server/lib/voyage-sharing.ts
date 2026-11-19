import { base64url } from "jose";

export type VoyageShare = {
  readonly voyageId: string;
  readonly generation: number;
  readonly slugHash: string;
  readonly issuedAtMs: number;
  readonly expiresAtMs: number;
  readonly revokedAtMs: number | null;
};

/** Server-side credential for an already authenticated viewer connection. */
export type VoyageShareGrant = Pick<VoyageShare, "voyageId" | "generation" | "slugHash">;

type Coordinate = { readonly lat: number; readonly lon: number };
type ViewerFix = Coordinate & { readonly capturedAtMs: number };
type PrivacyZone = Coordinate & { readonly radiusM: number };

export type VoyageShareFix = ViewerFix & {
  readonly voyageId: string;
  readonly segmentId: string;
  readonly receivedAtMs: number;
};

export type VoyageSharingSnapshot = {
  readonly voyageId: string;
  readonly share: VoyageShare | null;
  readonly paused: boolean;
  readonly delayS: number;
  readonly freshnessS: number;
  /** Null means the owner's privacy settings could not be loaded. */
  readonly privacyZones: readonly PrivacyZone[] | null;
  readonly fixes: readonly VoyageShareFix[];
};

export type VoyageViewerState =
  | { readonly status: "unavailable" }
  | {
      readonly status: "available";
      readonly current: ViewerFix;
      readonly segments: readonly (readonly ViewerFix[])[];
    };

export const unavailable = Object.freeze({ status: "unavailable" } as const);
export const shareCodePattern = /^[A-Za-z0-9_-]{43}$/;
const isTimestamp = (ms: number) => Number.isSafeInteger(ms) && ms >= 0;
const isSeconds = (seconds: number) => Number.isSafeInteger(seconds) && isTimestamp(seconds * 1000);

export async function hashSlug(slug: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(slug));
  return base64url.encode(new Uint8Array(digest));
}

/** Call on explicit owner opt-in or rotation. Persist the new record before returning its slug. */
export async function issueVoyageShare(
  voyageId: string,
  previous: VoyageShare | null,
  nowMs: number,
  expiresAtMs: number,
): Promise<{ slug: string; share: VoyageShare }> {
  const credential = await createVoyageShareCredential();
  return {
    slug: credential.slug,
    share: nextVoyageShare(voyageId, previous, nowMs, expiresAtMs, credential.slugHash),
  };
}

export async function createVoyageShareCredential() {
  const slug = base64url.encode(crypto.getRandomValues(new Uint8Array(32)));
  return { slug, slugHash: await hashSlug(slug) };
}

/** Build from the latest stored generation after the async credential generation. */
export function nextVoyageShare(
  voyageId: string,
  previous: VoyageShare | null,
  nowMs: number,
  expiresAtMs: number,
  slugHash: string,
): VoyageShare {
  const generation = (previous?.generation ?? 0) + 1;
  if (
    !voyageId ||
    !isTimestamp(nowMs) ||
    !isTimestamp(expiresAtMs) ||
    expiresAtMs <= nowMs ||
    !Number.isSafeInteger(generation) ||
    generation < 1 ||
    (previous && (previous.voyageId !== voyageId || nowMs < previous.issuedAtMs))
  ) {
    throw new RangeError("Invalid voyage share");
  }
  return { voyageId, generation, slugHash, issuedAtMs: nowMs, expiresAtMs, revokedAtMs: null };
}

export function revokeVoyageShare(share: VoyageShare, nowMs: number): VoyageShare {
  if (!isTimestamp(nowMs) || nowMs < share.issuedAtMs) {
    throw new RangeError("Invalid voyage share revocation time");
  }
  return share.revokedAtMs === null ? { ...share, revokedAtMs: nowMs } : share;
}

function activeShare(snapshot: VoyageSharingSnapshot, nowMs: number): VoyageShare | null {
  const { share, voyageId } = snapshot;
  if (
    !share ||
    share.voyageId !== voyageId ||
    !shareCodePattern.test(share.slugHash) ||
    !Number.isSafeInteger(share.generation) ||
    share.generation < 1 ||
    share.revokedAtMs !== null ||
    !isTimestamp(nowMs) ||
    !isTimestamp(share.issuedAtMs) ||
    !isTimestamp(share.expiresAtMs) ||
    nowMs < share.issuedAtMs ||
    nowMs >= share.expiresAtMs
  ) {
    return null;
  }
  return share;
}

/** Validate against the current share at connection time, including on reconnect. */
export async function authorizeVoyageViewer(
  snapshot: VoyageSharingSnapshot,
  slug: string,
  nowMs: number,
): Promise<VoyageShareGrant | null> {
  if (!shareCodePattern.test(slug)) return null;
  const share = activeShare(snapshot, nowMs);
  if (!share || share.slugHash !== (await hashSlug(slug))) return null;
  return { voyageId: share.voyageId, generation: share.generation, slugHash: share.slugHash };
}

/** Revalidate with the latest authoritative snapshot before every send. */
export function isVoyageShareGrantActive(
  snapshot: VoyageSharingSnapshot,
  grant: VoyageShareGrant | null,
  nowMs: number,
): boolean {
  const share = activeShare(snapshot, nowMs);
  return share !== null && matchesGrant(share, grant);
}

function matchesGrant(share: VoyageShare, grant: VoyageShareGrant | null): boolean {
  return (
    grant?.voyageId === share.voyageId &&
    grant.generation === share.generation &&
    grant.slugHash === share.slugHash
  );
}

export function voyageViewerState(
  snapshot: VoyageSharingSnapshot,
  grant: VoyageShareGrant | null,
  nowMs: number,
): VoyageViewerState {
  const share = activeShare(snapshot, nowMs);
  return share && matchesGrant(share, grant) ? projectViewer(snapshot, share, nowMs) : unavailable;
}

/** The caller must authenticate the owner before exposing these controls. */
export function voyageOwnerSharingState(
  snapshot: VoyageSharingSnapshot,
  nowMs: number,
): {
  sharing: "off" | "on" | "paused";
  delayS: number;
  grantGeneration?: number;
  preview: VoyageViewerState;
} {
  const share = activeShare(snapshot, nowMs);
  return {
    sharing: share ? (snapshot.paused ? "paused" : "on") : "off",
    delayS: snapshot.delayS,
    ...(share ? { grantGeneration: share.generation } : {}),
    preview: share ? projectViewer(snapshot, share, nowMs) : unavailable,
  };
}

function isCoordinate({ lat, lon }: Coordinate): boolean {
  return (
    Number.isFinite(lat) && Math.abs(lat) <= 90 && Number.isFinite(lon) && Math.abs(lon) <= 180
  );
}

const radians = (degrees: number) => (degrees * Math.PI) / 180;
// Match WaterKit's spherical model. Pad the boundary for floating-point rounding.
const EARTH_RADIUS_M = 6_371_008.8;
export const ZONE_MARGIN_M = 0.001;

export function distanceM(a: Coordinate, b: Coordinate): number {
  const latA = radians(a.lat);
  const latB = radians(b.lat);
  const lonDelta = radians(b.lon - a.lon);
  const y = Math.hypot(
    Math.cos(latB) * Math.sin(lonDelta),
    Math.cos(latA) * Math.sin(latB) - Math.sin(latA) * Math.cos(latB) * Math.cos(lonDelta),
  );
  const x = Math.sin(latA) * Math.sin(latB) + Math.cos(latA) * Math.cos(latB) * Math.cos(lonDelta);
  return EARTH_RADIUS_M * Math.atan2(y, x);
}

function canConnect(a: VoyageShareFix, b: VoyageShareFix, zones: readonly PrivacyZone[]): boolean {
  if (a.segmentId !== b.segmentId) return false;
  const lengthM = distanceM(a, b);
  // If the shortest great-circle arc hits a zone, the sum of the two distances
  // to the zone center is at most the arc length plus two radii (triangle inequality).
  // Split whenever we cannot prove the arc stays outside, even with both endpoints visible.
  return zones.every(
    (zone) =>
      distanceM(zone, a) + distanceM(zone, b) > lengthM + 2 * (zone.radiusM + ZONE_MARGIN_M),
  );
}

function eligibleFixes(
  snapshot: VoyageSharingSnapshot,
  issuedAtMs: number,
  cutoffMs: number,
  nowMs: number,
) {
  const byCaptureTime = new Map<number, VoyageShareFix | null>();
  for (const fix of snapshot.fixes) {
    const { capturedAtMs, receivedAtMs } = fix;
    if (
      fix.voyageId !== snapshot.voyageId ||
      !isTimestamp(capturedAtMs) ||
      !isTimestamp(receivedAtMs) ||
      capturedAtMs < issuedAtMs ||
      capturedAtMs > cutoffMs ||
      capturedAtMs > receivedAtMs ||
      receivedAtMs > nowMs
    ) {
      continue;
    }
    const prior = byCaptureTime.get(capturedAtMs);
    // Retries collapse. Conflicting fixes at the same time create a gap independent of order.
    if (
      !isCoordinate(fix) ||
      !fix.segmentId ||
      (prior !== undefined &&
        (prior === null ||
          prior.lat !== fix.lat ||
          prior.lon !== fix.lon ||
          prior.segmentId !== fix.segmentId))
    ) {
      byCaptureTime.set(capturedAtMs, null);
    } else {
      byCaptureTime.set(capturedAtMs, fix);
    }
  }
  return [...byCaptureTime.entries()].sort(([a], [b]) => a - b);
}

function projectViewer(
  snapshot: VoyageSharingSnapshot,
  share: VoyageShare,
  nowMs: number,
): VoyageViewerState {
  const { paused, privacyZones, delayS, freshnessS } = snapshot;
  if (
    paused ||
    !isSeconds(delayS) ||
    !isSeconds(freshnessS) ||
    freshnessS === 0 ||
    !privacyZones ||
    privacyZones.some(
      (zone) => !isCoordinate(zone) || !Number.isFinite(zone.radiusM) || zone.radiusM <= 0,
    )
  ) {
    return unavailable;
  }

  const cutoffMs = nowMs - delayS * 1000;
  const ordered = eligibleFixes(snapshot, share.issuedAtMs, cutoffMs, nowMs);
  const newest = ordered.at(-1);
  if (!newest || cutoffMs - newest[0] >= freshnessS * 1000) return unavailable;

  const segments: ViewerFix[][] = [];
  let segment: ViewerFix[] = [];
  let previous: VoyageShareFix | null = null;
  let current: ViewerFix | null = null;
  for (const [, fix] of ordered) {
    if (!fix || privacyZones.some((zone) => distanceM(zone, fix) <= zone.radiusM + ZONE_MARGIN_M)) {
      previous = null;
      current = null;
      continue;
    }
    if (!previous || !canConnect(previous, fix, privacyZones)) {
      segment = [];
      segments.push(segment);
    }
    // Allowlist every viewer field, including for the current fix and historical points.
    current = { lat: fix.lat, lon: fix.lon, capturedAtMs: fix.capturedAtMs };
    segment.push(current);
    previous = fix;
  }
  return current ? { status: "available", current, segments } : unavailable;
}
