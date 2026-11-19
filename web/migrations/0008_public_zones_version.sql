ALTER TABLE `sessions` ADD `public_track_started_at` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_track_ended_at` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `public_zones_version` integer;--> statement-breakpoint
ALTER TABLE `users` ADD `zones_version` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `users` ADD `zones_queued_version` integer DEFAULT 0 NOT NULL;