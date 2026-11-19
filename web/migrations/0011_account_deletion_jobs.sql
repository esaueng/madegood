CREATE TABLE `pending_r2_deletes` (
	`key` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `pending_r2_deletes_user` ON `pending_r2_deletes` (`user_id`,`created_at`);--> statement-breakpoint
ALTER TABLE `users` ADD `deletion_attempts` integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE `users` ADD `deletion_next_at` integer;