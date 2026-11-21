ALTER TABLE `users` ADD `public_profile_id` text;--> statement-breakpoint
ALTER TABLE `users` ADD `public_profile_username` text;--> statement-breakpoint
CREATE UNIQUE INDEX `users_public_profile_id_unique` ON `users` (`public_profile_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `users_public_profile_username_unique` ON `users` (`public_profile_username`);