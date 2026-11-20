declare namespace Cloudflare {
  interface Env {
    // Added by vitest.config.ts for test/apply-migrations.ts.
    TEST_MIGRATION_DB: D1Database;
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
