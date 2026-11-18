CREATE TABLE `legs` (
	`user_id` text NOT NULL,
	`id` text NOT NULL,
	`voyage_id` text NOT NULL,
	`from_name` text,
	`to_name` text,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`distance_m` real,
	PRIMARY KEY(`user_id`, `id`),
	FOREIGN KEY (`user_id`,`voyage_id`) REFERENCES `voyages`(`user_id`,`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `legs_user_voyage_id` ON `legs` (`user_id`,`voyage_id`,`id`);--> statement-breakpoint
CREATE TABLE `voyages` (
	`user_id` text NOT NULL,
	`id` text NOT NULL,
	`title` text NOT NULL,
	`boat_name` text,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	PRIMARY KEY(`user_id`, `id`),
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
