import { createRoute, z } from "@hono/zod-openapi";
import { and, eq, isNotNull } from "drizzle-orm";
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
import { sessions, users } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { deletePrefix, userPrefix } from "../lib/storage";

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
    "request with the same access token succeeds.",
  tags: ["account"],
  security,
  responses: {
    204: { description: "The account and its data are gone." },
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
  // Sessions, refresh tokens and privacy zones go with the user (ON DELETE CASCADE).
  await db.delete(users).where(eq(users.id, userId));
  await deletePrefix(c.env.TRACKS, userPrefix(userId));
  for (let i = 0; i < keys.length; i += 1000) await c.env.TRACKS.delete(keys.slice(i, i + 1000));
  return c.body(null, 204);
});
