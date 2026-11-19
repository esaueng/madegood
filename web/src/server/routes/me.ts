import { createRoute, z } from "@hono/zod-openapi";
import { and, eq, isNotNull, isNull, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import {
  cleanDisplayName,
  HANDLE_PATTERN,
  isReservedHandle,
  isUniqueViolation,
  toUserBody,
  UserBody,
} from "../auth/users";
import { clearSessionCookies } from "../auth/web-cookies";
import { sessions, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { deletePrefix, userPrefix } from "../lib/storage";
import { TRACK_SPORTS } from "../lib/track";
import { purgeAccountVoyages } from "../live/registry";

const security = [{ bearerAuth: [] }];

const getRoute = createRoute({
  method: "get",
  path: "/me",
  summary: "The signed-in user",
  tags: ["account"],
  security,
  responses: {
    200: { description: "The user.", content: { "application/json": { schema: UserBody } } },
    401: errorResponse("Missing or invalid access token, or the account no longer exists."),
  },
});

const UpdateMeRequest = z
  .object({
    displayName: z
      .string()
      .max(50)
      .nullable()
      .optional()
      .openapi({ description: "Blank or null clears it." }),
    handle: z
      .string()
      .transform((s) => s.trim().toLowerCase())
      .pipe(z.string().regex(HANDLE_PATTERN, "3–30 characters: a–z, 0–9 or _"))
      .optional()
      .openapi({
        type: "string",
        pattern: HANDLE_PATTERN.source,
        description: "Stored lowercase; uppercase input is lowercased.",
      }),
    units: z.enum(["metric", "imperial", "nautical"]).optional(),
    defaultVisibility: z.enum(["private", "unlisted", "public"]).optional(),
  })
  .strict()
  .openapi("UpdateMeRequest");

const patchRoute = createRoute({
  method: "patch",
  path: "/me",
  summary: "Update the signed-in user's profile and settings",
  tags: ["account"],
  security,
  request: {
    body: { required: true, content: { "application/json": { schema: UpdateMeRequest } } },
  },
  responses: {
    200: {
      description: "The updated user.",
      content: { "application/json": { schema: UserBody } },
    },
    400: errorResponse("The request body is invalid."),
    401: errorResponse("Missing or invalid access token, or the account no longer exists."),
    409: errorResponse("The handle is taken or reserved."),
  },
});

const deleteRoute = createRoute({
  method: "delete",
  path: "/me",
  summary: "Delete the signed-in user's account and all their data",
  description:
    "Deletes the user's track files and every database row that belongs to them. Repeating the " +
    "request with the same access token succeeds. A website request (session cookie) also gets " +
    "its session cookies cleared. The server holds no Sign in with Apple tokens (it never " +
    "redeems an authorization code), so there is nothing to revoke with Apple.",
  tags: ["account"],
  security,
  responses: {
    204: { description: "The account and its data are gone." },
    401: errorResponse("Missing or invalid access token."),
  },
});

const SportTotals = z.object({
  sessions: z.number().int(),
  distanceM: z.number().openapi({ description: "Sum of known distances, m." }),
  movingS: z.number().openapi({ description: "Sum of known moving times, s." }),
  durationS: z.number().openapi({ description: "Sum of known elapsed times, s." }),
});

const MeStats = SportTotals.extend({
  bySport: z.array(SportTotals.extend({ sport: z.enum(TRACK_SPORTS) })),
}).openapi("MeStats");

const statsRoute = createRoute({
  method: "get",
  path: "/me/stats",
  summary: "Totals over the signed-in user's sessions",
  description: "Counts and sums over every session the user has, overall and per sport.",
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  responses: {
    200: { description: "The totals.", content: { "application/json": { schema: MeStats } } },
    401: errorResponse("Missing or invalid access token."),
  },
});

const unknownUser = (c: Parameters<typeof apiError>[0]) =>
  apiError(c, 401, "unauthorized", "The account no longer exists.");

export const me = createRouter<AuthEnv>();
me.use("/me", requireAuth);

me.openapi(getRoute, async (c) => {
  const [user] = await drizzle(c.env.DB).select().from(users).where(eq(users.id, c.var.userId));
  return user ? c.json(toUserBody(user), 200) : unknownUser(c);
});

me.openapi(patchRoute, async (c) => {
  const body = c.req.valid("json");
  const db = drizzle(c.env.DB);
  const changes: Partial<typeof users.$inferInsert> = {};
  if (body.displayName !== undefined) changes.displayName = cleanDisplayName(body.displayName);
  if (body.units !== undefined) changes.units = body.units;
  if (body.defaultVisibility !== undefined) changes.defaultVisibility = body.defaultVisibility;
  if (body.handle !== undefined) {
    if (isReservedHandle(body.handle)) {
      return apiError(c, 409, "handle_taken", "That handle is not available.");
    }
    changes.handle = body.handle;
  }

  if (Object.keys(changes).length === 0) {
    const [user] = await db.select().from(users).where(eq(users.id, c.var.userId));
    return user ? c.json(toUserBody(user), 200) : unknownUser(c);
  }
  try {
    const [user] = await db
      .update(users)
      .set(changes)
      .where(eq(users.id, c.var.userId))
      .returning();
    return user ? c.json(toUserBody(user), 200) : unknownUser(c);
  } catch (err) {
    if (isUniqueViolation(err)) {
      return apiError(c, 409, "handle_taken", "That handle is not available.");
    }
    throw err;
  }
});

me.openapi(deleteRoute, async (c) => {
  const userId = c.var.userId;
  const db = drizzle(c.env.DB);
  // Sign in with Apple: the server never holds an Apple refresh or access token. The apps
  // send only the identity token, and the website asks for `code id_token` but verifies the
  // identity token alone and never exchanges the code (routes/web-auth.ts). With no token
  // stored there is nothing to send to Apple's /auth/revoke, and no Sign in with Apple
  // private key is needed (docs/app-store.md). Revisit this if the code is ever redeemed.
  //
  // Track keys outside the user prefix, in case any were ever written elsewhere; read
  // them before the rows that point at them are gone.
  const tracks = await db
    .select({ key: sessions.trackKey })
    .from(sessions)
    .where(and(eq(sessions.userId, userId), isNotNull(sessions.trackKey)));
  const keys = tracks.flatMap((t) =>
    t.key && !t.key.startsWith(userPrefix(userId)) ? [t.key] : [],
  );
  // Rows first, then objects (review of #37). A track upload attaches only to a live
  // session and otherwise deletes its object, so with this order an upload that overlaps
  // the deletion cannot leave a track behind. The prefix is deleted on every call, even
  // with the rows already gone, so retrying after an R2 failure still cleans up.
  // Sessions, voyages and their legs, refresh tokens and privacy zones cascade from the user.
  await db.delete(users).where(eq(users.id, userId));
  const cleanupTracks = async () => {
    await deletePrefix(c.env.TRACKS, userPrefix(userId));
    for (let i = 0; i < keys.length; i += 1000) await c.env.TRACKS.delete(keys.slice(i, i + 1000));
  };
  const cleanup = await Promise.allSettled([purgeAccountVoyages(c.env, userId), cleanupTracks()]);
  for (const result of cleanup) {
    if (result.status === "rejected") throw result.reason;
  }
  // The website's refresh rows are gone with the user; clear its cookies too, so the
  // browser stops presenting them. Apps (bearer tokens) get no cookies.
  if (c.req.header("Authorization") === undefined) clearSessionCookies(c);
  c.header("Cache-Control", "no-store");
  return c.body(null, 204);
});

me.openapi(statsRoute, async (c) => {
  const rows = await drizzle(c.env.DB)
    .select({
      sport: sessions.sport,
      sessions: sql<number>`count(*)`,
      distanceM: sql<number>`coalesce(sum(${sessions.distanceM}), 0)`,
      movingS: sql<number>`coalesce(sum(${sessions.movingS}), 0)`,
      durationS: sql<number>`coalesce(sum(${sessions.durationS}), 0)`,
    })
    .from(sessions)
    .where(and(eq(sessions.userId, c.var.userId), isNull(sessions.deletedAt)))
    .groupBy(sessions.sport)
    .orderBy(sessions.sport);
  const total = { sessions: 0, distanceM: 0, movingS: 0, durationS: 0 };
  for (const row of rows) {
    total.sessions += row.sessions;
    total.distanceM += row.distanceM;
    total.movingS += row.movingS;
    total.durationS += row.durationS;
  }
  return c.json({ ...total, bySport: rows }, 200);
});
