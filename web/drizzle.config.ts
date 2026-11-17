import { defineConfig } from "drizzle-kit";

// `pnpm db:generate` writes SQL migrations to the same folder wrangler reads
// (`migrations_dir` in wrangler.jsonc). Apply them with wrangler, never drizzle-kit.
export default defineConfig({
  dialect: "sqlite",
  schema: "./src/server/db/schema.ts",
  out: "./migrations",
});
