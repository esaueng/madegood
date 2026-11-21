import { and, eq, isNull } from "drizzle-orm";
import type { drizzle } from "drizzle-orm/d1";
import { sessionColumns, sessions, users } from "../db/schema";

/** Reads sessions and their owners' sharing state in the same D1 snapshot. */
export function selectReadableSessions(db: ReturnType<typeof drizzle>) {
  return db
    .select({
      session: sessionColumns,
      zonesVersion: users.zonesVersion,
      owner: { handle: users.handle, displayName: users.displayName },
    })
    .from(sessions)
    .innerJoin(users, and(eq(users.id, sessions.userId), isNull(users.deletedAt)));
}

export type ReadableSession = Awaited<ReturnType<typeof selectReadableSessions>>[number];
