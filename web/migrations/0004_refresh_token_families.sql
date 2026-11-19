ALTER TABLE `refresh_tokens` ADD `family_id` text;--> statement-breakpoint
CREATE INDEX `refresh_tokens_family` ON `refresh_tokens` (`family_id`);--> statement-breakpoint
UPDATE `refresh_tokens` SET `family_id` = `id` WHERE `family_id` IS NULL;