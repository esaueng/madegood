CREATE TABLE `export_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`status` text DEFAULT 'queued' NOT NULL,
	`cursor` integer DEFAULT 0 NOT NULL,
	`total_items` integer DEFAULT 0 NOT NULL,
	`next_part` integer DEFAULT 2 NOT NULL,
	`parts_json` text DEFAULT '[]' NOT NULL,
	`error` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`expires_at` integer,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `export_jobs_user_created` ON `export_jobs` (`user_id`,`created_at`);