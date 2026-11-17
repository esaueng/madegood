import { sql } from "drizzle-orm";
import { integer, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

// D1 schema. Phase 0 creates only the users table; sessions, tokens and the rest
// arrive with the API work in Phase 3 (docs/PLAN.md §7). Applied migrations are never
// edited: change this file, then run `pnpm db:generate` to add a new migration.

/** Unix epoch milliseconds. */
const timestamp = (name: string) => integer(name, { mode: "number" });

export const users = sqliteTable(
  "users",
  {
    id: text("id").primaryKey(),
    appleSub: text("apple_sub").notNull(),
    handle: text("handle").notNull(),
    displayName: text("display_name"),
    units: text("units", { enum: ["metric", "imperial", "nautical"] })
      .notNull()
      .default("nautical"),
    defaultVisibility: text("default_visibility", { enum: ["private", "unlisted", "public"] })
      .notNull()
      .default("private"),
    createdAt: timestamp("created_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
    deletedAt: timestamp("deleted_at"),
  },
  (table) => [
    uniqueIndex("users_apple_sub_unique").on(table.appleSub),
    uniqueIndex("users_handle_unique").on(table.handle),
  ],
);

export type User = typeof users.$inferSelect;
