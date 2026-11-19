CREATE TABLE `session_tombstones` (
	`id` text NOT NULL,
	`user_id` text NOT NULL,
	`deleted_at` integer DEFAULT (unixepoch('subsec') * 1000) NOT NULL,
	PRIMARY KEY(`user_id`, `id`),
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
ALTER TABLE `sessions` ADD `upload_revision` integer DEFAULT 0 NOT NULL;