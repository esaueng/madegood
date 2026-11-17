import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

// Applies migrations/*.sql the same way `wrangler d1 migrations apply` does. Safe to run
// more than once: migrations that were already applied are skipped.
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
