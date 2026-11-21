ALTER TABLE `users` ADD `public_profile_display_name` text;--> statement-breakpoint
-- Older blank names could have been cleared deliberately. Do not replace them at sign-in.
UPDATE `users` SET `display_name_edited` = 1 WHERE `display_name` IS NULL;
