CREATE TABLE `privacy_zones` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`lat` real NOT NULL,
	`lon` real NOT NULL,
	`radius_m` real NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `privacy_zones_user` ON `privacy_zones` (`user_id`);--> statement-breakpoint
CREATE TABLE `refresh_tokens` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`token_hash` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer DEFAULT (unixepoch('subsec') * 1000) NOT NULL,
	`revoked_at` integer,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `refresh_tokens_hash_unique` ON `refresh_tokens` (`token_hash`);--> statement-breakpoint
CREATE INDEX `refresh_tokens_user` ON `refresh_tokens` (`user_id`);--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`sport` text NOT NULL,
	`title` text,
	`notes` text,
	`visibility` text DEFAULT 'private' NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	`duration_s` real,
	`moving_s` real,
	`distance_m` real,
	`max_speed_mps` real,
	`avg_speed_mps` real,
	`min_lat` real,
	`min_lon` real,
	`max_lat` real,
	`max_lon` real,
	`start_geohash` text,
	`summary_json` text,
	`analyzer_version` text,
	`track_key` text,
	`wind_json` text,
	`created_at` integer DEFAULT (unixepoch('subsec') * 1000) NOT NULL,
	`updated_at` integer DEFAULT (unixepoch('subsec') * 1000) NOT NULL,
	`deleted_at` integer,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `sessions_user_started` ON `sessions` (`user_id`,`started_at`);--> statement-breakpoint
CREATE INDEX `sessions_public_started` ON `sessions` (`visibility`,`started_at`);