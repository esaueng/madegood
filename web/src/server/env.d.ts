// Secrets are not in wrangler.jsonc, so `wrangler types` cannot see them (CI has no
// .dev.vars). Declare them here; set them with `wrangler secret put` and locally in
// web/.dev.vars (docs/self-hosting.md).
interface WeatherKitSecrets {
  WEATHERKIT_PRIVATE_KEY?: string;
  WEATHERKIT_KEY_ID?: string;
  WEATHERKIT_TEAM_ID?: string;
  WEATHERKIT_SERVICE_ID?: string;
}

interface WorkerSecrets extends WeatherKitSecrets {
  /** Local opt-in switch for the synthetic live voyage transport. */
  VOYAGE_LIVE_LOCAL?: string;
  /** Signs access tokens (HS256). At least 32 characters, e.g. `openssl rand -base64 48`. */
  JWT_SIGNING_KEY: string;
  /** Enables the private voyage prototype in local development and tests. */
  VOYAGE_PRIVATE_LOCAL?: string;
}

interface DashboardVars {
  /** Public Apple download link, set on the Worker in the Cloudflare dashboard. */
  DOWNLOAD_URL?: string;
}

interface Env extends WorkerSecrets, DashboardVars {}

declare namespace Cloudflare {
  interface Env extends WorkerSecrets, DashboardVars {}
}
