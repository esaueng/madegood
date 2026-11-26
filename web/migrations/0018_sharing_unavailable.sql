-- Sharing is unavailable for now (src/server/lib/sharing-available.ts). Do what turning
-- sharing off does (PATCH /me sharingEnabled: false) for every account: the switch off,
-- every session private, the default private, the public profile off, and every live
-- voyage link unregistered. Readers check the switch, so nothing shared stays readable.
UPDATE `users` SET `sharing_enabled` = 0, `default_visibility` = 'private', `public_profile_id` = NULL;
--> statement-breakpoint
UPDATE `sessions` SET `visibility` = 'private', `updated_at` = unixepoch('subsec') * 1000 WHERE `visibility` != 'private';
--> statement-breakpoint
UPDATE `voyage_live_registry` SET `slug_hash` = NULL WHERE `slug_hash` IS NOT NULL;
