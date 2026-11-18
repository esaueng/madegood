import { describe, expect, it } from "vitest";
import {
  authorizeVoyageViewer,
  issueVoyageShare,
  isVoyageShareGrantActive,
  revokeVoyageShare,
  type VoyageShareFix,
  type VoyageSharingSnapshot,
  voyageOwnerSharingState,
  voyageViewerState,
} from "../src/server/lib/voyage-sharing";

const voyageId = "synthetic-voyage";
const startMs = 100_000;
const nowMs = 130_000;
const expiryMs = 200_000;
const unavailable = { status: "unavailable" };
const zone = { lat: 0, lon: 0, radiusM: 500 };

const point = (capturedAtMs: number, lon: number, lat = 0) => ({ lat, lon, capturedAtMs });

function fix(
  capturedAtMs: number,
  lon: number,
  overrides: Partial<VoyageShareFix> = {},
): VoyageShareFix {
  return {
    ...point(capturedAtMs, lon),
    voyageId,
    segmentId: "synthetic-leg",
    receivedAtMs: capturedAtMs,
    ...overrides,
  };
}

async function shared(overrides: Partial<VoyageSharingSnapshot> = {}) {
  const { slug, share } = await issueVoyageShare(voyageId, null, startMs, expiryMs);
  const snapshot: VoyageSharingSnapshot = {
    voyageId,
    share,
    paused: false,
    delayS: 10,
    freshnessS: 15,
    privacyZones: [],
    fixes: [fix(110_000, 0.02), fix(120_000, 0.03)],
    ...overrides,
  };
  const grant = await authorizeVoyageViewer(snapshot, slug, nowMs);
  if (!grant) throw new Error("Synthetic share did not authorize");
  return { slug, share, snapshot, grant };
}

describe("voyage share links", () => {
  it("requires explicit opt-in and scopes an opaque link and grant to its voyage", async () => {
    const { slug, share, snapshot, grant } = await shared();
    const privateVoyage = { ...snapshot, share: null };
    const otherVoyage = { ...snapshot, voyageId: "different-synthetic-voyage" };

    expect(slug).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(share.slugHash).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(share.slugHash).not.toBe(slug);
    expect(share.generation).toBe(1);
    expect(await authorizeVoyageViewer(privateVoyage, slug, nowMs)).toBeNull();
    expect(await authorizeVoyageViewer(otherVoyage, slug, nowMs)).toBeNull();
    expect(await authorizeVoyageViewer(snapshot, "wrong-link", nowMs)).toBeNull();
    expect(await authorizeVoyageViewer(snapshot, slug, startMs - 1)).toBeNull();
    expect(await authorizeVoyageViewer(snapshot, slug, startMs)).toStrictEqual(grant);
    expect(voyageViewerState(otherVoyage, grant, nowMs)).toStrictEqual(unavailable);
    expect(voyageViewerState(privateVoyage, grant, nowMs)).toStrictEqual(unavailable);
    expect(voyageOwnerSharingState(privateVoyage, nowMs)).toStrictEqual({
      sharing: "off",
      delayS: 10,
      preview: unavailable,
    });
    await expect(issueVoyageShare(voyageId, null, startMs, startMs)).rejects.toThrow(RangeError);
    await expect(issueVoyageShare(otherVoyage.voyageId, share, nowMs, expiryMs)).rejects.toThrow(
      RangeError,
    );
  });

  it("expires at the exact boundary for both active grants and reconnect", async () => {
    const { slug, snapshot, grant } = await shared({ fixes: [fix(expiryMs - 10_001, 0.02)] });

    expect(await authorizeVoyageViewer(snapshot, slug, expiryMs - 1)).toStrictEqual(grant);
    expect(voyageViewerState(snapshot, grant, expiryMs - 1).status).toBe("available");
    expect(await authorizeVoyageViewer(snapshot, slug, expiryMs)).toBeNull();
    expect(isVoyageShareGrantActive(snapshot, grant, expiryMs)).toBe(false);
    expect(voyageViewerState(snapshot, grant, expiryMs)).toStrictEqual(unavailable);
    expect(voyageOwnerSharingState(snapshot, expiryMs).sharing).toBe("off");
  });

  it("revokes at the committed change and rotates without reusing credentials or old fixes", async () => {
    const { slug, share, snapshot, grant } = await shared();
    expect(voyageViewerState(snapshot, grant, nowMs - 1).status).toBe("available");
    const revoked = revokeVoyageShare(share, nowMs);
    const stopped = { ...snapshot, share: revoked };
    expect(revokeVoyageShare(revoked, nowMs + 1).revokedAtMs).toBe(nowMs);
    expect(await authorizeVoyageViewer(stopped, slug, nowMs)).toBeNull();
    expect(isVoyageShareGrantActive(stopped, grant, nowMs)).toBe(false);
    expect(voyageViewerState(stopped, grant, nowMs)).toStrictEqual(unavailable);
    expect(voyageOwnerSharingState(stopped, nowMs).sharing).toBe("off");

    const next = await issueVoyageShare(voyageId, revoked, nowMs, expiryMs);
    expect(next.share.generation).toBe(share.generation + 1);
    expect(next.slug).not.toBe(slug);
    const rotated = {
      ...snapshot,
      share: next.share,
      fixes: [...snapshot.fixes, fix(nowMs, 0.04)],
    };
    expect(await authorizeVoyageViewer(rotated, slug, nowMs)).toBeNull();
    expect(isVoyageShareGrantActive(rotated, grant, nowMs)).toBe(false);
    const nextGrant = await authorizeVoyageViewer(rotated, next.slug, nowMs);
    expect(voyageViewerState(rotated, nextGrant, nowMs)).toStrictEqual(unavailable);
    expect(voyageViewerState(rotated, nextGrant, nowMs + 10_000)).toStrictEqual({
      status: "available",
      current: point(nowMs, 0.04),
      segments: [[point(nowMs, 0.04)]],
    });
  });
});

describe("voyage viewer projection", () => {
  it("uses the same delayed projection for the owner preview and clears it on pause", async () => {
    const { slug, snapshot, grant } = await shared();
    const view = voyageViewerState(snapshot, grant, nowMs);
    expect(voyageOwnerSharingState(snapshot, nowMs)).toStrictEqual({
      sharing: "on",
      grantGeneration: 1,
      delayS: 10,
      preview: view,
    });
    expect(view).toStrictEqual({
      status: "available",
      current: point(120_000, 0.03),
      segments: [[point(110_000, 0.02), point(120_000, 0.03)]],
    });

    const paused = { ...snapshot, paused: true };
    expect(voyageOwnerSharingState(paused, nowMs)).toStrictEqual({
      sharing: "paused",
      grantGeneration: 1,
      delayS: 10,
      preview: unavailable,
    });
    expect(voyageViewerState(paused, grant, nowMs)).toStrictEqual(unavailable);
    const reconnected = await authorizeVoyageViewer(paused, slug, nowMs);
    expect(voyageViewerState(paused, reconnected, nowMs)).toStrictEqual(unavailable);
  });

  it("applies exact capture-time delay and freshness independently of local receipt", async () => {
    const { snapshot, grant } = await shared({
      fixes: [
        fix(99_999, 0.01, { receivedAtMs: nowMs }),
        fix(120_000, 0.02, { receivedAtMs: 129_000 }),
      ],
    });
    expect(voyageViewerState(snapshot, grant, nowMs - 1)).toStrictEqual(unavailable);
    const view = {
      status: "available",
      current: point(120_000, 0.02),
      segments: [[point(120_000, 0.02)]],
    };
    expect(voyageViewerState(snapshot, grant, nowMs)).toStrictEqual(view);
    expect(voyageViewerState(snapshot, grant, 144_999)).toStrictEqual(view);
    expect(voyageViewerState(snapshot, grant, 145_000)).toStrictEqual(unavailable);
    const justReceived = { ...snapshot, fixes: [fix(120_000, 0.02, { receivedAtMs: 145_000 })] };
    expect(voyageViewerState(justReceived, grant, 145_000)).toStrictEqual(unavailable);
  });

  it("ignores future-of-receipt fixes even after their capture time would have aged into view", async () => {
    const { snapshot, grant } = await shared({
      delayS: 0,
      fixes: [
        fix(130_001, 0.04, { receivedAtMs: nowMs }),
        fix(129_000, 0.02),
        fix(130_002, 0.05, { receivedAtMs: 160_000 }),
      ],
    });
    const view = {
      status: "available",
      current: point(129_000, 0.02),
      segments: [[point(129_000, 0.02)]],
    };
    expect(voyageViewerState(snapshot, grant, nowMs)).toStrictEqual(view);
    expect(voyageViewerState(snapshot, grant, 130_002)).toStrictEqual(view);
  });

  it("sorts and deduplicates backfill by capture time, preserving recording breaks", async () => {
    const backfill = fix(108_000, 0.012, { receivedAtMs: nowMs });
    const { slug, snapshot, grant } = await shared({
      fixes: [
        fix(120_000, 0.04, { segmentId: "second-synthetic-leg" }),
        backfill,
        fix(112_000, 0.014),
        fix(102_000, 0.01),
        fix(108_000, 0.012, { receivedAtMs: 129_000 }),
        fix(120_000, 0.9, { voyageId: "different-synthetic-voyage" }),
      ],
    });
    const expected = {
      status: "available",
      current: point(120_000, 0.04),
      segments: [
        [point(102_000, 0.01), point(108_000, 0.012), point(112_000, 0.014)],
        [point(120_000, 0.04)],
      ],
    };
    expect(voyageViewerState(snapshot, grant, nowMs)).toStrictEqual(expected);
    const reconnect = { ...snapshot, fixes: [...snapshot.fixes].reverse() };
    expect(
      voyageViewerState(reconnect, await authorizeVoyageViewer(reconnect, slug, nowMs), nowMs),
    ).toStrictEqual(expected);
  });

  it("does not pick either of two conflicting fixes at the current capture time", async () => {
    const { snapshot, grant } = await shared({
      privacyZones: [zone],
      fixes: [fix(110_000, 0.02), fix(120_000, 0.02), fix(120_000, 0)],
    });
    expect(voyageViewerState(snapshot, grant, nowMs)).toStrictEqual(unavailable);
    expect(
      voyageViewerState({ ...snapshot, fixes: [...snapshot.fixes].reverse() }, grant, nowMs),
    ).toStrictEqual(unavailable);
  });

  it("clears the entire projection at entry and keeps hidden fixes and metadata out of replay", async () => {
    const ownerOnly = { title: "synthetic home port", log: { lat: 0, lon: 0 }, bounds: [0, 0] };
    const hiddenFix = { ...fix(120_000, 0), ...ownerOnly };
    const laterFix = { ...fix(123_000, 0.03), ...ownerOnly };
    const { snapshot, grant, slug } = await shared({
      privacyZones: [zone],
      fixes: [fix(105_000, 0.02), hiddenFix, laterFix],
    });
    const withPrivateMetadata = { ...snapshot, ...ownerOnly };
    expect(voyageViewerState(withPrivateMetadata, grant, nowMs - 1)).toStrictEqual({
      status: "available",
      current: point(105_000, 0.02),
      segments: [[point(105_000, 0.02)]],
    });
    expect(voyageViewerState(withPrivateMetadata, grant, nowMs)).toStrictEqual(unavailable);
    expect(voyageOwnerSharingState(withPrivateMetadata, nowMs).preview).toStrictEqual(unavailable);
    expect(
      voyageViewerState(snapshot, await authorizeVoyageViewer(snapshot, slug, nowMs), nowMs),
    ).toStrictEqual(unavailable);

    const afterExit = 133_000;
    const earlierFix = fix(105_000, 0.02);
    const beforeBackfill = { ...withPrivateMetadata, fixes: [earlierFix, laterFix] };
    expect(voyageViewerState(beforeBackfill, grant, afterExit)).toStrictEqual({
      status: "available",
      current: point(123_000, 0.03),
      segments: [[point(105_000, 0.02), point(123_000, 0.03)]],
    });
    const withBackfill = {
      ...withPrivateMetadata,
      fixes: [laterFix, { ...hiddenFix, receivedAtMs: afterExit }, earlierFix],
    };
    const expected = {
      status: "available",
      current: point(123_000, 0.03),
      segments: [[point(105_000, 0.02)], [point(123_000, 0.03)]],
    };
    expect(voyageViewerState(withBackfill, grant, afterExit)).toStrictEqual(expected);
    expect(
      voyageViewerState(
        withBackfill,
        await authorizeVoyageViewer(withBackfill, slug, afterExit),
        afterExit,
      ),
    ).toStrictEqual(expected);
  });

  it.each([
    { name: "sparse crossing", center: 0, a: -0.02, b: 0.02 },
    { name: "antimeridian crossing", center: 180, a: 179.98, b: -179.98 },
  ])("splits outside endpoints of a $name", async ({ center, a, b }) => {
    const { snapshot, grant } = await shared({
      privacyZones: [{ ...zone, lon: center }],
      fixes: [fix(110_000, a), fix(120_000, b)],
    });
    expect(voyageViewerState(snapshot, grant, nowMs)).toStrictEqual({
      status: "available",
      current: point(120_000, b),
      segments: [[point(110_000, a)], [point(120_000, b)]],
    });
  });

  it("includes the privacy radius boundary and fails closed when zones are unavailable", async () => {
    const edgeLon = (zone.radiusM * 180) / (6_371_008.8 * Math.PI);
    const { snapshot, grant } = await shared({
      privacyZones: [zone],
      fixes: [fix(110_000, 0.02), fix(120_000, edgeLon)],
    });
    expect(voyageViewerState(snapshot, grant, nowMs)).toStrictEqual(unavailable);
    expect(voyageViewerState({ ...snapshot, privacyZones: null }, grant, nowMs)).toStrictEqual(
      unavailable,
    );
    const invalidZone = { ...zone, radiusM: Number.NaN };
    expect(
      voyageViewerState({ ...snapshot, privacyZones: [invalidZone] }, grant, nowMs),
    ).toStrictEqual(unavailable);
  });
});
