import { createRoute, z } from "@hono/zod-openapi";
import { and, desc, eq, isNull, lt, or, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { optionalAuth, type ViewerEnv } from "../auth/middleware";
import { publicProfileLookup } from "../auth/users";
import { sessions, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { TRACK_SPORTS } from "../lib/track";
import { decodeCursor, encodeCursor } from "./sessions";

// Only an enabled profile can be found by its current URL. It lists public sessions
// and their totals, with a preview available to its owner even before they share a session.

const PAGE_DEFAULT = 20;
const PAGE_MAX = 50;

/** Anyone may call it; a token, when sent, identifies the viewer. */
const optionalSecurity: Record<string, string[]>[] = [{ bearerAuth: [] }, {}];

const isoTime = z.iso.datetime({ offset: true }).openapi({ format: "date-time" });

const ProfileParams = z.object({
  profileKey: z
    .string()
    .max(68)
    .transform((s) => s.toLowerCase())
    .openapi({
      param: { name: "profileKey", in: "path" },
      type: "string",
      description: "The opaque profile ID, optionally prefixed with a chosen @username and a ~.",
      example: "@skipper_4821~f81570bf-2352-4d5f-aaf0-af1d995ccc28",
    }),
});

const Totals = z.object({
  sessions: z.number().int(),
  distanceM: z.number().openapi({ description: "Sum of known distances, m." }),
  movingS: z.number().openapi({ description: "Sum of known moving times, s." }),
  durationS: z.number().openapi({ description: "Sum of known elapsed times, s." }),
});

const ProfileTotals = Totals.extend({
  bySport: z.array(Totals.extend({ sport: z.enum(TRACK_SPORTS) })),
}).openapi("ProfileTotals", { description: "Totals over the user's public sessions only." });

const PublicSessionSummary = z
  .object({
    id: z.string().openapi({ format: "uuid" }),
    sport: z.enum(TRACK_SPORTS),
    title: z.string().nullable(),
    startedAt: isoTime,
    durationS: z.number().nullable(),
    movingS: z.number().nullable(),
    distanceM: z.number().nullable(),
    maxSpeedMps: z.number().nullable().openapi({ description: "Best 2 s window, m/s." }),
    avgSpeedMps: z.number().nullable(),
  })
  .openapi("PublicSessionSummary", {
    description: "A public session as a profile lists it; GET /sessions/{id} has the rest.",
  });

const PublicProfile = z
  .object({
    displayName: z.string().nullable(),
    isOwner: z.boolean().openapi({ description: "Whether the caller is this user." }),
    totals: ProfileTotals,
    sessions: z.array(PublicSessionSummary).openapi({ description: "Newest first." }),
    nextCursor: z
      .string()
      .nullable()
      .openapi({ description: "Pass as `cursor` for the next page; null on the last page." }),
  })
  .openapi("PublicProfile");

const profileRoute = createRoute({
  method: "get",
  path: "/users/{profileKey}",
  operationId: "getUserProfile",
  summary: "A user's public profile and public sessions",
  description:
    "The display name, totals and a page of public sessions. Disabled profiles return 404 " +
    "to everyone. An enabled profile with no public sessions is visible only to its owner. " +
    "`totals` covers every public session across all pages.",
  tags: ["users"],
  security: optionalSecurity,
  middleware: [optionalAuth] as const,
  request: {
    params: ProfileParams,
    query: z.object({
      cursor: z.string().max(200).optional().openapi({ description: "From `nextCursor`." }),
      limit: z.coerce
        .number()
        .int()
        .min(1)
        .max(PAGE_MAX)
        .optional()
        .openapi({ type: "integer", description: `Page size, ${PAGE_DEFAULT} by default.` }),
    }),
  },
  responses: {
    200: {
      description: "The profile.",
      content: { "application/json": { schema: PublicProfile } },
    },
    400: errorResponse("The cursor or limit is invalid."),
    401: errorResponse("An access token was sent but is invalid."),
    404: errorResponse("The profile is unavailable."),
  },
});

const notFound = (c: Parameters<typeof apiError>[0]) =>
  apiError(c, 404, "not_found", "No such profile.");

export const userRoutes = createRouter<ViewerEnv>();

userRoutes.openapi(profileRoute, async (c) => {
  const { profileKey } = c.req.valid("param");
  const { cursor, limit = PAGE_DEFAULT } = c.req.valid("query");
  // Visibility can change at any time; never let a shared cache keep a profile.
  c.header("Cache-Control", "private, no-store");
  const after = cursor === undefined ? null : decodeCursor(cursor);
  if (cursor !== undefined && !after) return apiError(c, 400, "invalid_request", "Bad cursor.");
  const account = publicProfileLookup(profileKey);
  if (!account) return notFound(c);

  const db = drizzle(c.env.DB);
  // The account, the totals and the page are read in one batch: one round trip that D1
  // runs as a single transaction. So an unknown profile key and an account without public
  // sessions cost the same (no timing difference reveals which accounts exist), and all
  // three reads see the same state (no display name next to sessions a concurrent
  // deletion or visibility change has already removed).
  const shown = and(account, eq(sessions.visibility, "public"), isNull(sessions.deletedAt));
  // Newest first; the ID breaks ties, as in GET /sessions.
  const page = after
    ? or(
        lt(sessions.startedAt, after[0]),
        and(eq(sessions.startedAt, after[0]), lt(sessions.id, after[1])),
      )
    : undefined;
  const userQuery = db
    .select({ id: users.id, displayName: users.displayName })
    .from(users)
    .where(account);
  const totalsQuery = db
    .select({
      sport: sessions.sport,
      sessions: sql<number>`count(*)`,
      distanceM: sql<number>`coalesce(sum(${sessions.distanceM}), 0)`,
      movingS: sql<number>`coalesce(sum(${sessions.movingS}), 0)`,
      durationS: sql<number>`coalesce(sum(${sessions.durationS}), 0)`,
    })
    .from(sessions)
    .innerJoin(users, eq(sessions.userId, users.id))
    .where(shown)
    .groupBy(sessions.sport)
    .orderBy(sessions.sport);
  const pageQuery = db
    .select({
      id: sessions.id,
      sport: sessions.sport,
      title: sessions.title,
      startedAt: sessions.startedAt,
      durationS: sessions.durationS,
      movingS: sessions.movingS,
      distanceM: sessions.distanceM,
      maxSpeedMps: sessions.maxSpeedMps,
      avgSpeedMps: sessions.avgSpeedMps,
    })
    .from(sessions)
    .innerJoin(users, eq(sessions.userId, users.id))
    .where(and(shown, page))
    .orderBy(desc(sessions.startedAt), desc(sessions.id))
    .limit(limit + 1);
  const [[user], bySport, rows] = await db.batch([userQuery, totalsQuery, pageQuery]);
  if (!user) return notFound(c);
  const isOwner = c.var.viewerId === user.id;
  if (bySport.length === 0 && !isOwner) return notFound(c);

  const totals = { sessions: 0, distanceM: 0, movingS: 0, durationS: 0 };
  for (const row of bySport) {
    totals.sessions += row.sessions;
    totals.distanceM += row.distanceM;
    totals.movingS += row.movingS;
    totals.durationS += row.durationS;
  }

  const items = rows.slice(0, limit);
  const last = items.at(-1);

  return c.json(
    {
      displayName: user.displayName,
      isOwner,
      totals: { ...totals, bySport },
      sessions: items.map((s) => ({ ...s, startedAt: new Date(s.startedAt).toISOString() })),
      nextCursor: rows.length > limit && last ? encodeCursor(last) : null,
    },
    200,
  );
});
