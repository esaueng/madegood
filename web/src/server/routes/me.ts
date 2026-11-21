import { createRoute, z } from "@hono/zod-openapi";
import { and, eq, isNull, ne, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { type AuthEnv, requireAuth, requireToken } from "../auth/middleware";
import {
  cleanDisplayName,
  HANDLE_PATTERN,
  isReservedHandle,
  isUniqueViolation,
  toUserBody,
  UserBody,
} from "../auth/users";
import { clearSessionCookies } from "../auth/web-cookies";
import { sessions, users, voyageLiveRegistry } from "../db/schema";
import { requestAccountDeletion, runScheduledDeletion } from "../lib/account-deletion";
import { apiError, errorResponse } from "../lib/errors";
import { logFailure } from "../lib/logging";
import { createRouter } from "../lib/router";
import { TRACK_SPORTS } from "../lib/track";
import { liveVoyage } from "../live/registry";

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
    sharingEnabled: z
      .boolean()
      .optional()
      .openapi({
        description:
          "false stops all sharing at once: every session becomes private, the default " +
          "visibility becomes private, live voyage links stop working, and nothing can be " +
          "shared again until it is set back to true. Setting it to true shares nothing by itself.",
      }),
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
    409: errorResponse(
      "The handle is taken or reserved (`handle_taken`), or `defaultVisibility` would share " +
        "while sharing is turned off (`sharing_disabled`).",
    ),
  },
});

const DeleteMeRequest = z
  .object({
    userId: z
      .string()
      .min(1)
      .openapi({
        description:
          "The ID of the account the user confirmed deleting (GET /me `id`). A request for any " +
          "other account than the signed-in one is refused, so a stale confirmation can never " +
          "delete whoever is signed in now.",
      }),
  })
  .strict()
  .openapi("DeleteMeRequest");

const deleteRoute = createRoute({
  method: "delete",
  path: "/me",
  summary: "Delete the signed-in user's account and all their data",
  description:
    "Starts deleting the account: from this response on it cannot sign in or change anything, " +
    "and every sign-in is revoked. The server then removes the track files and every database " +
    "row that belongs to the account, retrying until done; the account record itself goes " +
    "about 20 minutes later. Repeating the request with the same access token succeeds. A " +
    "website request (session cookie) also gets its session cookies cleared. The server holds " +
    "no Sign in with Apple tokens (it never redeems an authorization code), so there is " +
    "nothing to revoke with Apple.",
  tags: ["account"],
  security,
  request: {
    body: { required: true, content: { "application/json": { schema: DeleteMeRequest } } },
  },
  responses: {
    202: { description: "The account is being deleted, or is already gone." },
    400: errorResponse("The request body is invalid."),
    401: errorResponse("Missing or invalid access token."),
    409: errorResponse("`userId` is not the signed-in account (`account_mismatch`)."),
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

/** The account, unless it is gone or being deleted. */
const activeUser = (userId: string) => and(eq(users.id, userId), isNull(users.deletedAt));

const unknownUser = (c: Parameters<typeof apiError>[0]) =>
  apiError(c, 401, "unauthorized", "The account no longer exists.");

/** Revokes every live voyage grant of the account (after sharing is turned off). */
async function revokeLiveShares(env: Env, userId: string) {
  if (!env.VOYAGE_LIVE) return;
  const { results } = await env.DB.prepare(
    "SELECT voyage_id AS voyageId FROM voyage_live_registry WHERE user_id = ?",
  )
    .bind(userId)
    .all<{ voyageId: string }>();
  for (const { voyageId } of results) {
    const key = { userId, voyageId };
    await liveVoyage(env, key)
      .configure(key, { action: "revoke" })
      .catch((error: unknown) => logFailure("live_share_revoke_failed", error));
  }
}

const sharingDisabled = (c: Parameters<typeof apiError>[0]) =>
  apiError(c, 409, "sharing_disabled", "Sharing is turned off for this account.");

export const me = createRouter<AuthEnv>();
// DELETE /me must work for an account already being deleted (a retry), so /me checks the
// token only; GET and PATCH treat a deleting account as gone.
me.use("/me", requireToken);

me.openapi(getRoute, async (c) => {
  const [user] = await drizzle(c.env.DB).select().from(users).where(activeUser(c.var.userId));
  return user ? c.json(toUserBody(user), 200) : unknownUser(c);
});

me.openapi(patchRoute, async (c) => {
  const body = c.req.valid("json");
  const db = drizzle(c.env.DB);
  const changes: Partial<typeof users.$inferInsert> = {};
  if (body.displayName !== undefined) changes.displayName = cleanDisplayName(body.displayName);
  if (body.units !== undefined) changes.units = body.units;
  if (body.defaultVisibility !== undefined) changes.defaultVisibility = body.defaultVisibility;
  const shares = body.defaultVisibility !== undefined && body.defaultVisibility !== "private";
  const stopSharing = body.sharingEnabled === false;
  if (stopSharing && shares) return sharingDisabled(c);
  if (body.sharingEnabled !== undefined) changes.sharingEnabled = body.sharingEnabled;
  if (stopSharing) changes.defaultVisibility = "private";
  if (body.handle !== undefined) {
    if (isReservedHandle(body.handle)) {
      return apiError(c, 409, "handle_taken", "That handle is not available.");
    }
    changes.handle = body.handle;
  }

  if (Object.keys(changes).length === 0) {
    const [user] = await db.select().from(users).where(activeUser(c.var.userId));
    return user ? c.json(toUserBody(user), 200) : unknownUser(c);
  }
  // A non-private default needs sharing on, checked in the same statement, unless this
  // request turns it on.
  const allowed =
    shares && body.sharingEnabled !== true
      ? and(activeUser(c.var.userId), eq(users.sharingEnabled, true))
      : activeUser(c.var.userId);
  try {
    const update = db.update(users).set(changes).where(allowed).returning();
    let user: typeof users.$inferSelect | undefined;
    if (stopSharing) {
      // One D1 batch (a transaction): the switch, every session it makes private, and every
      // live voyage link it unregisters, so an old link never resolves again even after
      // sharing is turned back on. Writes that share check the switch in their own
      // statement, so none can land between these.
      const [updated] = await db.batch([
        update,
        db
          .update(sessions)
          .set({ visibility: "private", updatedAt: Date.now() })
          .where(and(eq(sessions.userId, c.var.userId), ne(sessions.visibility, "private"))),
        db
          .update(voyageLiveRegistry)
          .set({ slugHash: null })
          .where(eq(voyageLiveRegistry.userId, c.var.userId)),
      ]);
      [user] = updated;
      // Then revoke each live grant, which also deletes its positions. Viewers already get
      // nothing (live/voyage-live.ts checks the switch); this is cleanup, so best effort.
      if (user) c.executionCtx.waitUntil(revokeLiveShares(c.env, c.var.userId));
    } else {
      [user] = await update;
    }
    if (user) return c.json(toUserBody(user), 200);
    if (shares) {
      const [active] = await db
        .select({ id: users.id })
        .from(users)
        .where(activeUser(c.var.userId));
      if (active) return sharingDisabled(c);
    }
    return unknownUser(c);
  } catch (err) {
    if (isUniqueViolation(err)) {
      return apiError(c, 409, "handle_taken", "That handle is not available.");
    }
    throw err;
  }
});

me.openapi(deleteRoute, async (c) => {
  const userId = c.var.userId;
  if (c.req.valid("json").userId !== userId) {
    return apiError(
      c,
      409,
      "account_mismatch",
      "You are signed in to a different account than the one you chose to delete.",
    );
  }
  // Sign in with Apple: the server never holds an Apple refresh or access token. The apps
  // send only the identity token, and the website asks for `code id_token` but verifies the
  // identity token alone and never exchanges the code (routes/web-auth.ts). With no token
  // stored there is nothing to send to Apple's /auth/revoke, and no Sign in with Apple
  // private key is needed (docs/app-store.md). Revisit this if the code is ever redeemed.
  //
  // The deletion is a durable job (lib/account-deletion.ts): marked and revoked here in one
  // D1 batch, then swept once in this request (so the data is gone when it answers, unless
  // storage fails) and by the scheduled sweep until the account record goes too.
  await requestAccountDeletion(c.env.DB, userId);
  // A failed pass is retried by the scheduled sweep with backoff (runScheduledDeletion).
  await runScheduledDeletion(c.env, userId);
  // The website's refresh rows are gone; clear its cookies too, so the browser stops
  // presenting them. Apps (bearer tokens) get no cookies.
  if (c.req.header("Authorization") === undefined) clearSessionCookies(c);
  c.header("Cache-Control", "no-store");
  return c.body(null, 202);
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
