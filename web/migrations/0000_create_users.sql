CREATE TABLE `users` (
	`id` text PRIMARY KEY NOT NULL,
	`apple_sub` text NOT NULL,
	`handle` text NOT NULL,
	`display_name` text,
	`units` text DEFAULT 'nautical' NOT NULL,
	`default_visibility` text DEFAULT 'private' NOT NULL,
	`created_at` integer DEFAULT (unixepoch('subsec') * 1000) NOT NULL,
	`deleted_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `users_apple_sub_unique` ON `users` (`apple_sub`);--> statement-breakpoint
CREATE UNIQUE INDEX `users_handle_unique` ON `users` (`handle`);