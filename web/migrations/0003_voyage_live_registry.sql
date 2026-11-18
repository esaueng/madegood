CREATE TABLE `voyage_live_registry` (
	`user_id` text NOT NULL,
	`voyage_id` text NOT NULL,
	`generation` integer DEFAULT 0 NOT NULL,
	`slug_hash` text,
	PRIMARY KEY(`user_id`, `voyage_id`)
);
--> statement-breakpoint
CREATE UNIQUE INDEX `voyage_live_slug_hash` ON `voyage_live_registry` (`slug_hash`);