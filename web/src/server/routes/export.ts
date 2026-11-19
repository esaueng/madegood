import { createRoute, z } from "@hono/zod-openapi";
import { and, asc, eq, isNull } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { toUserBody } from "../auth/users";
import { legs, privacyZones, sessions, users, voyages } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { userPrefix } from "../lib/storage";
import { type ZipEntry, zipResponseBody } from "../lib/zip";

// GET /me/export: everything the account holds, as one ZIP streamed from D1 and R2. Track
// files pass through chunk by chunk, never whole in memory; only the JSON documents are
// built in memory, and those are bounded by the row limits below.

/** Track bytes an export may carry: well under ZIP's 4 GiB, and bounded Worker CPU (CRC). */
export const EXPORT_MAX_TRACK_BYTES = 1024 * 1024 * 1024;
/** Track files an export may carry (ZIP without ZIP64 holds 65,535 entries). */
export const EXPORT_MAX_TRACKS = 20_000;

export const exportTooLarge = (trackCount: number, trackBytes: number) =>
  trackCount > EXPORT_MAX_TRACKS || trackBytes > EXPORT_MAX_TRACK_BYTES;

const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());

const parseJson = (text: string | null): unknown => {
  if (text === null) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
};

const json = (value: unknown) => new TextEncoder().encode(`${JSON.stringify(value, null, 2)}\n`);

const README = `MadeGood account export

account.json         Your profile and settings, and Apple's identifier for your sign-in.
sessions.json        Every session in your account: times, sport, title, notes, visibility,
                     statistics, the analysis summary and wind estimate, the bounding box.
privacy-zones.json   Your privacy zones (center and radius).
voyages.json         Private voyages and their legs, if you synced any.
tracks/sessions/     Each session's track as you uploaded it (gzipped JSON, track v1,
                     docs/formats.md in the MadeGood source). Privacy zones are not cut
                     out: these are your own files.
tracks/voyages/      Voyage leg tracks, in the same format.

Units are SI: metres, seconds, metres per second, degrees. Times are UTC (ISO 8601).
A track deleted while the export was running is left out.
`;

const exportRoute = createRoute({
  method: "get",
  path: "/me/export",
  operationId: "exportAccount",
  summary: "Download all of the signed-in user's data",
  description:
    "A ZIP archive, streamed: `account.json`, `sessions.json`, `privacy-zones.json`, " +
    "`voyages.json`, a README and every track file as uploaded (owner versions, not the " +
    `shared projection). Refused with 413 above ${EXPORT_MAX_TRACKS} track files or ` +
    `${EXPORT_MAX_TRACK_BYTES} bytes of tracks.`,
  tags: ["account"],
  security: [{ bearerAuth: [] }],
  middleware: [requireAuth] as const,
  responses: {
    200: {
      description: "The archive.",
      content: { "application/zip": { schema: z.string().openapi({ format: "binary" }) } },
    },
    401: errorResponse("Missing or invalid access token, or the account no longer exists."),
    413: errorResponse("The account holds too much to export in one archive (`export_too_large`)."),
  },
});

export const exportRoutes = createRouter<AuthEnv>();

exportRoutes.openapi(exportRoute, async (c) => {
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  const [user] = await db.select().from(users).where(eq(users.id, userId));
  if (!user) return apiError(c, 401, "unauthorized", "The account no longer exists.");

  const [sessionRows, zoneRows, voyageRows, legRows] = await Promise.all([
    db
      .select()
      .from(sessions)
      .where(and(eq(sessions.userId, userId), isNull(sessions.deletedAt)))
      .orderBy(asc(sessions.startedAt), asc(sessions.id)),
    db.select().from(privacyZones).where(eq(privacyZones.userId, userId)),
    db
      .select()
      .from(voyages)
      .where(eq(voyages.userId, userId))
      .orderBy(asc(voyages.startedAt), asc(voyages.id)),
    db
      .select()
      .from(legs)
      .where(eq(legs.userId, userId))
      .orderBy(asc(legs.startedAt), asc(legs.id)),
  ]);

  // Sizes of every object under the user's prefix, to refuse an oversized export up front
  // rather than fail halfway through the download.
  const sizes = new Map<string, number>();
  let cursor: string | undefined;
  do {
    const page = await c.env.TRACKS.list({ prefix: userPrefix(userId), cursor, limit: 1000 });
    for (const object of page.objects) sizes.set(object.key, object.size);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  const tracks: { name: string; key: string }[] = [];
  for (const session of sessionRows) {
    if (session.trackKey) {
      tracks.push({ name: `tracks/sessions/${session.id}.track.v1.gz`, key: session.trackKey });
    }
  }
  for (const leg of legRows) {
    const key = `${userPrefix(userId)}voyages/${leg.voyageId}/legs/${leg.id}/track.v1.gz`;
    if (sizes.has(key)) {
      tracks.push({ name: `tracks/voyages/${leg.voyageId}/${leg.id}.track.v1.gz`, key });
    }
  }
  let trackBytes = 0;
  for (const track of tracks) {
    // A key outside the prefix (none are written today) is measured on its own.
    const size = sizes.get(track.key) ?? (await c.env.TRACKS.head(track.key))?.size ?? 0;
    trackBytes += size;
  }
  if (exportTooLarge(tracks.length, trackBytes)) {
    return apiError(
      c,
      413,
      "export_too_large",
      "This account holds too much to export at once. Download sessions one at a time instead.",
    );
  }

  const legsByVoyage = new Map<string, typeof legRows>();
  for (const leg of legRows)
    legsByVoyage.set(leg.voyageId, [...(legsByVoyage.get(leg.voyageId) ?? []), leg]);
  const entries: ZipEntry[] = [
    { name: "README.txt", data: async () => new TextEncoder().encode(README) },
    {
      name: "account.json",
      data: async () =>
        json({
          ...toUserBody(user),
          appleUserId: user.appleSub,
          exportedAt: new Date().toISOString(),
        }),
    },
    {
      name: "sessions.json",
      data: async () =>
        json(
          sessionRows.map((s) => ({
            id: s.id,
            sport: s.sport,
            title: s.title,
            notes: s.notes,
            visibility: s.visibility,
            startedAt: iso(s.startedAt),
            endedAt: iso(s.endedAt),
            durationS: s.durationS,
            movingS: s.movingS,
            distanceM: s.distanceM,
            maxSpeedMps: s.maxSpeedMps,
            avgSpeedMps: s.avgSpeedMps,
            bounds:
              s.minLat === null
                ? null
                : { minLat: s.minLat, minLon: s.minLon, maxLat: s.maxLat, maxLon: s.maxLon },
            startGeohash: s.startGeohash,
            summary: parseJson(s.summaryJson),
            wind: parseJson(s.windJson),
            analyzerVersion: s.analyzerVersion,
            uploadRevision: s.uploadRevision,
            track: s.trackKey ? `tracks/sessions/${s.id}.track.v1.gz` : null,
            createdAt: iso(s.createdAt),
            updatedAt: iso(s.updatedAt),
          })),
        ),
    },
    {
      name: "privacy-zones.json",
      data: async () =>
        json(zoneRows.map((z) => ({ id: z.id, lat: z.lat, lon: z.lon, radiusM: z.radiusM }))),
    },
    {
      name: "voyages.json",
      data: async () =>
        json(
          voyageRows.map((v) => ({
            id: v.id,
            title: v.title,
            boatName: v.boatName,
            startedAt: iso(v.startedAt),
            endedAt: iso(v.endedAt),
            legs: (legsByVoyage.get(v.id) ?? []).map((l) => ({
              id: l.id,
              fromName: l.fromName,
              toName: l.toName,
              startedAt: iso(l.startedAt),
              endedAt: iso(l.endedAt),
              distanceM: l.distanceM,
            })),
          })),
        ),
    },
    ...tracks.map(
      (track): ZipEntry => ({
        name: track.name,
        data: async () => (await c.env.TRACKS.get(track.key))?.body ?? null,
      }),
    ),
  ];

  const now = new Date();
  const day = now.toISOString().slice(0, 10);
  return new Response(zipResponseBody(entries, now), {
    status: 200,
    headers: {
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="madegood-export-${day}.zip"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
});
