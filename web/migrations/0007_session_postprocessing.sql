ALTER TABLE `sessions` ADD `track_etag` text;--> statement-breakpoint
ALTER TABLE `sessions` ADD `processed_etag` text;--> statement-breakpoint
ALTER TABLE `sessions` ADD `postprocess_status` text;--> statement-breakpoint
ALTER TABLE `sessions` ADD `track_started_at` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `track_ended_at` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_min_lat` real;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_min_lon` real;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_max_lat` real;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_max_lon` real;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_track_started_at` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_track_ended_at` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_zones_version` integer;--> statement-breakpoint
ALTER TABLE `users` ADD `zones_version` integer DEFAULT 0 NOT NULL;