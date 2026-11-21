import { createRoute, z } from "@hono/zod-openapi";
import { and, eq, isNull, sql } from "drizzle-orm";
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
import { sessions, users } from "../db/schema";
import { requestAccountDeletion, runScheduledDeletion } from "../lib/account-deletion";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { TRACK_SPORTS } from "../lib/track";

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
    userId: z.string().min(1).optional().openapi({
      description: "If provided, the account ID the user intended to update.",
    }),
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
    publicProfileEnabled: z.boolean().optional().openapi({
      description: "Enable or disable the public profile. Re-enabling creates a new link.",
    }),
    publicProfileDisplayName: z.string().max(50).nullable().optional().openapi({
      description: "The user-entered name for the public profile. Blank or null clears it.",
    }),
    publicProfileUsername: z
      .string()
      .transform((s) => s.trim().toLowerCase())
      .pipe(z.string().regex(HANDLE_PATTERN, "3–30 characters: a–z, 0–9 or _"))
      .nullable()
      .optional()
      .openapi({ description: "A custom public URL username. Null restores an opaque URL." }),
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
    409: errorResponse("The account differs, or the handle or profile username is unavailable."),
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

export const me = createRouter<AuthEnv>();
// DELETE /me must work for an account already being deleted (a retry), so /me checks the
// token only; GET and PATCH treat a deleting account as gone.
me.use("/me", requireToken);

me.openapi(getRoute, async (c) => {
  c.header("Cache-Control", "private, no-store");
  const [user] = await drizzle(c.env.DB).select().from(users).where(activeUser(c.var.userId));
  return user ? c.json(toUserBody(user), 200) : unknownUser(c);
});

me.openapi(patchRoute, async (c) => {
  c.header("Cache-Control", "private, no-store");
  const body = c.req.valid("json");
  if (body.userId !== undefined && body.userId !== c.var.userId) {
    return apiError(c, 409, "account_mismatch", "You are signed in to a different account.");
  }
  const db = drizzle(c.env.DB);
  const changes: Partial<typeof users.$inferInsert> = {};
  if (body.displayName !== undefined) {
    changes.displayName = cleanDisplayName(body.displayName);
    changes.displayNameEdited = true;
  }
  if (body.publicProfileDisplayName !== undefined) {
    changes.publicProfileDisplayName = cleanDisplayName(body.publicProfileDisplayName);
  }
  if (body.units !== undefined) changes.units = body.units;
  if (body.defaultVisibility !== undefined) changes.defaultVisibility = body.defaultVisibility;
  if (body.handle !== undefined) {
    if (isReservedHandle(body.handle)) {
      return apiError(c, 409, "handle_taken", "That handle is not available.");
    }
    changes.handle = body.handle;
  }
  if (body.publicProfileUsername !== undefined) {
    if (body.publicProfileUsername && isReservedHandle(body.publicProfileUsername)) {
      return apiError(c, 409, "handle_taken", "That profile username is not available.");
    }
    changes.publicProfileUsername = body.publicProfileUsername;
  }

  if (Object.keys(changes).length === 0 && body.publicProfileEnabled === undefined) {
    const [user] = await db.select().from(users).where(activeUser(c.var.userId));
    return user ? c.json(toUserBody(user), 200) : unknownUser(c);
  }
  try {
    const [user] = await db
      .update(users)
      .set({
        ...changes,
        // Enabling twice (including retries) keeps the existing link in a single update.
        publicProfileId: body.publicProfileEnabled
          ? sql`coalesce(${users.publicProfileId}, ${crypto.randomUUID()})`
          : body.publicProfileEnabled === false
            ? null
            : undefined,
      })
      .where(activeUser(c.var.userId))
      .returning();
    return user ? c.json(toUserBody(user), 200) : unknownUser(c);
  } catch (err) {
    if (isUniqueViolation(err)) {
      return apiError(c, 409, "handle_taken", "That handle or profile username is not available.");
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
