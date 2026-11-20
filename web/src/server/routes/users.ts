import { createRoute, z } from "@hono/zod-openapi";
import { and, desc, eq, isNull, lt, or, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { optionalAuth, type ViewerEnv } from "../auth/middleware";
import { HANDLE_PATTERN } from "../auth/users";
import { sessions, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { TRACK_SPORTS } from "../lib/track";
import { decodeCursor, encodeCursor } from "./sessions";

// GET /users/:handle: a user's public profile (docs/PLAN.md §6 `/u/:handle`).
//
// Only sessions whose visibility is `public` count or appear here; unlisted sessions are
// for people who were given the link, so a profile never lists them. Each session is a
// summary row with no positions, bounds, track times, wind, summary object or notes:
// nothing a privacy zone would have to cut. Of the account, only the handle and display
// name are shown, never its ID, units, settings or dates.
//
// A profile exists for others only while the user has at least one public session.
// Sessions are private by default, so an account that never shared anything (or is being
// deleted) gets the same 404 as a handle nobody has. The owner always sees their own
// profile, with exactly what others would see, so they can check it before sharing.

const PAGE_DEFAULT = 20;
const PAGE_MAX = 50;

/** Anyone may call it; a token, when sent, identifies the viewer. */
const optionalSecurity: Record<string, string[]>[] = [{ bearerAuth: [] }, {}];

const isoTime = z.iso.datetime({ offset: true }).openapi({ format: "date-time" });

const HandleParams = z.object({
  handle: z
    .string()
    .max(64)
    .transform((s) => s.toLowerCase())
    .openapi({
      param: { name: "handle", in: "path" },
      type: "string",
      description: "The user's handle, in either case. Stored lowercase.",
      example: "skipper_4821",
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
    handle: z.string().openapi({ example: "skipper_4821" }),
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
  path: "/users/{handle}",
  operationId: "getUserProfile",
  summary: "A user's public profile and public sessions",
  description:
    "The handle, display name, totals and a page of sessions, all over the user's public " +
    "sessions only (never unlisted or private ones). Anyone else gets 404 for a user with " +
    "no public sessions, as for an unknown handle; the user themself always gets their " +
    "profile as others would see it. `totals` covers every public session, not just this page.",
  tags: ["users"],
  security: optionalSecurity,
  middleware: [optionalAuth] as const,
  request: {
    params: HandleParams,
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
    404: errorResponse("No such user, or the user has no public sessions."),
  },
});

const notFound = (c: Parameters<typeof apiError>[0]) =>
  apiError(c, 404, "not_found", "No such profile.");

export const userRoutes = createRouter<ViewerEnv>();

userRoutes.openapi(profileRoute, async (c) => {
  const { handle } = c.req.valid("param");
  const { cursor, limit = PAGE_DEFAULT } = c.req.valid("query");
  // Visibility can change at any time; never let a shared cache keep a profile.
  c.header("Cache-Control", "private, no-cache");
  const after = cursor === undefined ? null : decodeCursor(cursor);
  if (cursor !== undefined && !after) return apiError(c, 400, "invalid_request", "Bad cursor.");
  if (!HANDLE_PATTERN.test(handle)) return notFound(c);

  const db = drizzle(c.env.DB);
  const [user] = await db
    .select({ id: users.id, handle: users.handle, displayName: users.displayName })
    .from(users)
    .where(and(eq(users.handle, handle), isNull(users.deletedAt)));
  if (!user) return notFound(c);

  const shown = and(
    eq(sessions.userId, user.id),
    eq(sessions.visibility, "public"),
    isNull(sessions.deletedAt),
  );
  const bySport = await db
    .select({
      sport: sessions.sport,
      sessions: sql<number>`count(*)`,
      distanceM: sql<number>`coalesce(sum(${sessions.distanceM}), 0)`,
      movingS: sql<number>`coalesce(sum(${sessions.movingS}), 0)`,
      durationS: sql<number>`coalesce(sum(${sessions.durationS}), 0)`,
    })
    .from(sessions)
    .where(shown)
    .groupBy(sessions.sport)
    .orderBy(sessions.sport);
  const isOwner = c.var.viewerId === user.id;
  if (bySport.length === 0 && !isOwner) return notFound(c);

  const totals = { sessions: 0, distanceM: 0, movingS: 0, durationS: 0 };
  for (const row of bySport) {
    totals.sessions += row.sessions;
    totals.distanceM += row.distanceM;
    totals.movingS += row.movingS;
    totals.durationS += row.durationS;
  }

  // Newest first; the ID breaks ties, as in GET /sessions.
  const page = after
    ? or(
        lt(sessions.startedAt, after[0]),
        and(eq(sessions.startedAt, after[0]), lt(sessions.id, after[1])),
      )
    : undefined;
  const rows = await db
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
    .where(and(shown, page))
    .orderBy(desc(sessions.startedAt), desc(sessions.id))
    .limit(limit + 1);
  const items = rows.slice(0, limit);
  const last = items.at(-1);

  return c.json(
    {
      handle: user.handle,
      displayName: user.displayName,
      isOwner,
      totals: { ...totals, bySport },
      sessions: items.map((s) => ({ ...s, startedAt: new Date(s.startedAt).toISOString() })),
      nextCursor: rows.length > limit && last ? encodeCursor(last) : null,
    },
    200,
  );
});
