-- Keep the column compatible with the previous Worker and discard any wind its queue
-- consumer finishes between migration and deployment.
UPDATE sessions SET wind_json = NULL WHERE wind_json IS NOT NULL;
--> statement-breakpoint
CREATE TRIGGER sessions_discard_legacy_wind
AFTER UPDATE OF wind_json ON sessions
WHEN NEW.wind_json IS NOT NULL
BEGIN
  UPDATE sessions SET wind_json = NULL WHERE id = NEW.id;
END;
