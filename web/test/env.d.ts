declare namespace Cloudflare {
  interface Env {
    // Added by vitest.config.ts for test/apply-migrations.ts.
    TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
  }
}
