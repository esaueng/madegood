import { z } from "@hono/zod-openapi";
import { eq } from "drizzle-orm";
import type { DrizzleD1Database } from "drizzle-orm/d1";
import { type User, users } from "../db/schema";
import { AccountDeleting } from "./account-state";

type Db = DrizzleD1Database<Record<string, unknown>>;

// Words a handle must not be, because they would read as official or clash with routes.
const RESERVED_HANDLES = new Set([
  "about",
  "admin",
  "api",
  "app",
  "help",
  "login",
  "logout",
  "madegood",
  "me",
  "privacy",
  "root",
  "sessions",
  "settings",
  "signin",
  "signup",
  "support",
  "system",
  "terms",
  "users",
  "voyages",
  "www",
]);

export const isReservedHandle = (handle: string) => RESERVED_HANDLES.has(handle);

export const UserBody = z
  .object({
    id: z.string(),
    handle: z.string().openapi({ example: "skipper_4821" }),
    displayName: z.string().nullable(),
    units: z.enum(["metric", "imperial", "nautical"]),
    defaultVisibility: z.enum(["private", "unlisted", "public"]),
    sharingEnabled: z.boolean().openapi({
      description:
        "Whether the account may share anything. While false every session is private and " +
        "nothing can be made unlisted or public.",
    }),
    createdAt: z.string().datetime().openapi({ format: "date-time" }),
  })
  .openapi("User");

export const toUserBody = (user: User): z.infer<typeof UserBody> => ({
  id: user.id,
  handle: user.handle,
  displayName: user.displayName,
  units: user.units,
  defaultVisibility: user.defaultVisibility,
  sharingEnabled: user.sharingEnabled,
  createdAt: new Date(user.createdAt).toISOString(),
});

/** True when a D1 error (possibly wrapped by Drizzle) is a UNIQUE constraint failure. */
export function isUniqueViolation(err: unknown): boolean {
  for (let e = err; e instanceof Error; e = e.cause) {
    if (e.message.includes("UNIQUE constraint failed")) return true;
  }
  return false;
}

/** Display names are trimmed and capped; blank means none. */
export function cleanDisplayName(name: string | null | undefined): string | null {
  const trimmed = name?.trim().slice(0, 50);
  return trimmed ? trimmed : null;
}

const randomDigits = (n: number) =>
  Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => String(b % 10)).join("");

/** A handle base from a display name: "Anne-Marie Ø." → "annemarie". */
function handleBase(displayName: string | null): string {
  const base = (displayName ?? "")
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "")
    .slice(0, 20);
  return base.length >= 3 && !isReservedHandle(base) ? base : "sailor";
}

function* handleCandidates(displayName: string | null) {
  const base = handleBase(displayName);
  if (base !== "sailor") yield base;
  for (let i = 0; i < 5; i++) yield `${base}_${randomDigits(4)}`;
  // Practically unreachable; 12 random digits never collide in practice.
  yield `sailor_${randomDigits(12)}`;
}

export { AccountDeleting } from "./account-state";

/**
 * Finds the user for an Apple `sub`, creating one with a generated handle on first sign-in.
 * Apple sends the name only on the first authorization, so a provided display name also
 * fills in an existing account that has none. Throws AccountDeleting for an account that
 * is being deleted (lib/account-deletion.ts).
 */
export async function findOrCreateUser(
  db: Db,
  appleSub: string,
  displayName: string | null,
): Promise<{ user: User; created: boolean }> {
  const [existing] = await db.select().from(users).where(eq(users.appleSub, appleSub));
  if (existing?.deletedAt != null) throw new AccountDeleting(existing.id, existing.deletedAt);
  if (existing) {
    if (existing.displayName === null && displayName !== null) {
      const [updated] = await db
        .update(users)
        .set({ displayName })
        .where(eq(users.id, existing.id))
        .returning();
      return { user: updated ?? existing, created: false };
    }
    return { user: existing, created: false };
  }

  for (const handle of handleCandidates(displayName)) {
    try {
      const [user] = await db
        .insert(users)
        .values({ id: crypto.randomUUID(), appleSub, handle, displayName })
        .returning();
      if (user) return { user, created: true };
    } catch (err) {
      if (!isUniqueViolation(err)) throw err;
      // A concurrent first sign-in for the same Apple account won the race.
      const [raced] = await db.select().from(users).where(eq(users.appleSub, appleSub));
      if (raced?.deletedAt != null) throw new AccountDeleting(raced.id, raced.deletedAt);
      if (raced) return { user: raced, created: false };
      // Otherwise the handle was taken; try the next candidate.
    }
  }
  throw new Error("could not generate a unique handle");
}
