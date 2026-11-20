import { generateKeyPairSync } from "node:crypto";
import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Separate from vite.config.ts: tests run the Worker in workerd with local D1/R2,
// without the client build plugins.
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Deliver post-processing messages at once instead of after wrangler.jsonc's
          // 5 s batch window, so tests that wait for the consumer stay fast.
          queueConsumers: {
            "madegood-postprocess": {
              maxBatchSize: 10,
              maxBatchTimeout: 0,
              maxRetries: 5,
              deadLetterQueue: "madegood-postprocess-dlq",
            },
            "madegood-exports": { maxBatchSize: 1, maxBatchTimeout: 0, maxRetries: 3 },
          },
          bindings: {
            TEST_MIGRATIONS: migrations,
            WEATHERKIT_PRIVATE_KEY: privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
            WEATHERKIT_KEY_ID: "test-weather-key",
            WEATHERKIT_TEAM_ID: "test-weather-team",
            WEATHERKIT_SERVICE_ID: "test.weatherkit",
            VOYAGE_LIVE_LOCAL: "1",
            VOYAGE_PRIVATE_LOCAL: "1",
            // The website's Sign in with Apple Services ID (a placeholder).
            APPLE_WEB_CLIENT_ID: "app.madegood.web",
            // Tests run on their own origin; the production canonical address would redirect them.
            CANONICAL_ORIGIN: "",
            // A test-only key; real keys are Wrangler secrets.
            JWT_SIGNING_KEY: "test-signing-key-not-a-secret-0123456789",
          },
        },
      }),
    ],
    test: {
      include: ["test/**/*.test.ts"],
      setupFiles: ["./test/apply-migrations.ts"],
    },
  };
});
