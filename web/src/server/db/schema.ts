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
    /** Set when the account is being deleted (lib/account-deletion.ts); the row is the job. */
    deletedAt: timestamp("deleted_at"),
    /** Failed passes of the deletion job, for backoff and alerting. */
    deletionAttempts: integer("deletion_attempts").notNull().default(0),
    /** When the deletion job runs next; null means as soon as possible. */
    deletionNextAt: timestamp("deletion_next_at"),
    /**
     * Bumped in the same D1 batch as every privacy zone change. Public derived data
     * (sessions.public_*) is served only while it was computed at the current version.
     */
    zonesVersion: integer("zones_version").notNull().default(0),
    /**
     * The zones_version whose reprocessing was last queued. Behind zones_version means a
     * zone change still has to requeue the user's sessions: the next zone change, track
     * upload or the scheduled sweep (lib/postprocess.ts) does it.
     */
    zonesQueuedVersion: integer("zones_queued_version").notNull().default(0),
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
    /**
     * The device's upload revision for the metadata and track (increasing per session).
     * A PUT with a lower revision is rejected, so a delayed older upload can never
     * replace newer data, for example a track the user has since trimmed.
     */
    uploadRevision: integer("upload_revision").notNull().default(0),
    windJson: text("wind_json"),
    // Post-processing (lib/postprocess.ts). `trackEtag` is the attached track object's
    // ETag; the derived columns below belong to it once `processedEtag` equals it. Every
    // track upload and newer revision clears them, so they never describe another track.
    trackEtag: text("track_etag"),
    processedEtag: text("processed_etag"),
    /** `done`, `too_large` or `invalid` for `processedEtag`; null while pending. */
    postprocessStatus: text("postprocess_status", { enum: ["done", "too_large", "invalid"] }),
    /** First and last valid GPS fix, epoch ms. Owner only. */
    trackStartedAt: timestamp("track_started_at"),
    trackEndedAt: timestamp("track_ended_at"),
    /**
     * Bounding box of the fixes others may see (privacy zones and fixes beyond the map
     * cut out, as in the shared track). min/max_lat/lon above cover the whole track and
     * are the owner's only. West > east when a box crosses the antimeridian.
     */
    publicMinLat: real("public_min_lat"),
    publicMinLon: real("public_min_lon"),
    publicMaxLat: real("public_max_lat"),
    publicMaxLon: real("public_max_lon"),
    /** First and last fix others may see (zones applied), epoch ms. */
    publicTrackStartedAt: timestamp("public_track_started_at"),
    publicTrackEndedAt: timestamp("public_track_ended_at"),
    /** users.zones_version the public_* columns were computed with; null when not computed. */
    publicZonesVersion: integer("public_zones_version"),
    // Cold image misses share one queued refresh per fingerprint until the marker expires.
    ogQueuedFingerprint: text("og_queued_fingerprint"),
    ogQueuedAt: timestamp("og_queued_at"),
    createdAt: timestamp("created_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
    updatedAt: timestamp("updated_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
    deletedAt: timestamp("deleted_at"),
  },
  (table) => [
    index("sessions_user_started").on(table.userId, table.startedAt),
    index("sessions_public_started").on(table.visibility, table.startedAt),
  ],
);

/**
 * Session IDs an account deleted. A later PUT for one returns 410, so a device that still
 * has the recording can never bring a deleted session back. Removed with the account.
 */
export const sessionTombstones = sqliteTable(
  "session_tombstones",
  {
    id: text("id").notNull(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    deletedAt: timestamp("deleted_at").notNull().default(sql`(unixepoch('subsec') * 1000)`),
  },
  (table) => [primaryKey({ columns: [table.userId, table.id] })],
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

/**
 * R2 objects nothing should reference any more (lib/r2-garbage.ts). A key is recorded in
 * the same D1 batch that stops a row referencing it (or before an upload writes it), so no
 * object is ever left without a record; collecting deletes the object, then the row.
 * Deliberately no foreign key: rows outlive the account until its deletion collects them.
 */
export const pendingR2Deletes = sqliteTable(
  "pending_r2_deletes",
  {
    key: text("key").primaryKey(),
    userId: text("user_id").notNull(),
    createdAt: timestamp("created_at").notNull(),
    /**
     * The collector (or upload discarding its own object) that holds this key, and since
     * when: it deletes the object only after winning this claim, and an upload attaches its
     * key only while the row is unclaimed (lib/r2-garbage.ts).
     */
    claim: text("claim"),
    claimedAt: timestamp("claimed_at"),
  },
  (table) => [index("pending_r2_deletes_user").on(table.userId, table.createdAt)],
);

/**
 * Account export jobs (lib/export-job.ts). The frozen snapshot and the built ZIP parts live
 * in R2 under the user's prefix (`exports/<id>/`), so deleting the account removes them.
 * `cursor` is the next item of the snapshot's plan to write; `nextPart` the part number it
 * goes into (part 1, the manifest, is written last).
 */
export const exportJobs = sqliteTable(
  "export_jobs",
  {
    id: text("id").primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    status: text("status", { enum: ["queued", "building", "ready", "failed", "expired"] })
      .notNull()
      .default("queued"),
    cursor: integer("cursor").notNull().default(0),
    totalItems: integer("total_items").notNull().default(0),
    nextPart: integer("next_part").notNull().default(2),
    /** JSON: [{ part, bytes, key, listing }] for every committed part. */
    partsJson: text("parts_json").notNull().default("[]"),
    /** The step attempt that holds the claim on (cursor, nextPart), and since when. */
    attempt: text("attempt"),
    attemptAt: timestamp("attempt_at"),
    error: text("error"),
    createdAt: timestamp("created_at").notNull(),
    updatedAt: timestamp("updated_at").notNull(),
    expiresAt: timestamp("expires_at"),
  },
  (table) => [index("export_jobs_user_created").on(table.userId, table.createdAt)],
);

export type ExportJob = typeof exportJobs.$inferSelect;
