import { sql } from "drizzle-orm";
import {
  foreignKey,
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

// D1 schema (docs/PLAN.md §7). Applied migrations are never edited: change this file,
// then run `pnpm db:generate` to add a new migration, and keep each change compatible
// with the version already deployed (docs/self-hosting.md).

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

/** Refresh tokens, stored as SHA-256 hashes and rotated on every use. */
export const refreshTokens = sqliteTable(
  "refresh_tokens",
  {
    id: text("id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    tokenHash: text("token_hash").notNull(),
    expiresAt: timestamp("expires_at").notNull(),
    createdAt: timestamp("created_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
    revokedAt: timestamp("revoked_at"),
    /**
     * The sign-in this token descends from: the first token's ID, shared by every
     * successor. Signing out ends the whole family. Null only on rows from before 0004,
     * which that migration backfills with the row's own ID.
     */
    familyId: text("family_id"),
    /**
     * Which client the sign-in belongs to: `app` (the iPhone, JSON refresh) or `web` (the
     * website, cookie refresh). Each refresh endpoint accepts only its own kind, so a web
     * refresh token never yields an app token without `sid`. Every successor keeps it.
     */
    client: text("client", { enum: ["app", "web"] })
      .notNull()
      .default("app"),
  },
  (table) => [
    uniqueIndex("refresh_tokens_hash_unique").on(table.tokenHash),
    index("refresh_tokens_user").on(table.userId),
    index("refresh_tokens_family").on(table.familyId),
  ],
);

/**
 * One recorded session. `id` is the device-generated UUID, so uploads are idempotent
 * (AGENTS.md). Units are SI; times are epoch milliseconds. The track itself is in R2 at
 * `track_key`; `summary_json` is the track v1 summary (docs/metrics.md).
 */
export const sessions = sqliteTable(
  "sessions",
  {
    id: text("id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    sport: text("sport", {
      enum: ["sailing", "windsurfing", "motorboating", "kayak", "canoe", "sup"],
    }).notNull(),
    title: text("title"),
    notes: text("notes"),
    visibility: text("visibility", { enum: ["private", "unlisted", "public"] })
      .notNull()
      .default("private"),
    startedAt: timestamp("started_at").notNull(),
    endedAt: timestamp("ended_at"),
    durationS: real("duration_s"),
    movingS: real("moving_s"),
    distanceM: real("distance_m"),
    maxSpeedMps: real("max_speed_mps"),
    avgSpeedMps: real("avg_speed_mps"),
    minLat: real("min_lat"),
    minLon: real("min_lon"),
    maxLat: real("max_lat"),
    maxLon: real("max_lon"),
    startGeohash: text("start_geohash"),
    summaryJson: text("summary_json"),
    analyzerVersion: text("analyzer_version"),
    trackKey: text("track_key"),
    windJson: text("wind_json"),
    createdAt: timestamp("created_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
    updatedAt: timestamp("updated_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
    deletedAt: timestamp("deleted_at"),
  },
  (table) => [
    index("sessions_user_started").on(table.userId, table.startedAt),
    index("sessions_public_started").on(table.visibility, table.startedAt),
  ],
);

/** Areas around a user's home or launch spots, cut from tracks that others can see. */
export const privacyZones = sqliteTable(
  "privacy_zones",
  {
    id: text("id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    lat: real("lat").notNull(),
    lon: real("lon").notNull(),
    radiusM: real("radius_m").notNull(),
  },
  (table) => [index("privacy_zones_user").on(table.userId)],
);

export type Session = typeof sessions.$inferSelect;
export type RefreshToken = typeof refreshTokens.$inferSelect;
export type PrivacyZone = typeof privacyZones.$inferSelect;

/** Private sync records. UUIDs are stable within an account. */
export const voyages = sqliteTable(
  "voyages",
  {
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    id: text("id").notNull(),
    title: text("title").notNull(),
    boatName: text("boat_name"),
    startedAt: timestamp("started_at").notNull(),
    endedAt: timestamp("ended_at"),
  },
  (table) => [primaryKey({ columns: [table.userId, table.id] })],
);

export const legs = sqliteTable(
  "legs",
  {
    userId: text("user_id").notNull(),
    id: text("id").notNull(),
    voyageId: text("voyage_id").notNull(),
    fromName: text("from_name"),
    toName: text("to_name"),
    startedAt: timestamp("started_at").notNull(),
    endedAt: timestamp("ended_at").notNull(),
    distanceM: real("distance_m"),
  },
  (table) => [
    primaryKey({ columns: [table.userId, table.id] }),
    foreignKey({
      columns: [table.userId, table.voyageId],
      foreignColumns: [voyages.userId, voyages.id],
    }).onDelete("cascade"),
    index("legs_user_voyage_id").on(table.userId, table.voyageId, table.id),
  ],
);

/** Locates live objects and remains available for purge retries after account deletion. */
export const voyageLiveRegistry = sqliteTable(
  "voyage_live_registry",
  {
    userId: text("user_id").notNull(),
    voyageId: text("voyage_id").notNull(),
    generation: integer("generation").notNull().default(0),
    slugHash: text("slug_hash"),
  },
  (table) => [
    primaryKey({ columns: [table.userId, table.voyageId] }),
    uniqueIndex("voyage_live_slug_hash").on(table.slugHash),
  ],
);
