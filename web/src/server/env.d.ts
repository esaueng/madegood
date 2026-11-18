// Secrets are not in wrangler.jsonc, so `wrangler types` cannot see them (CI has no
// .dev.vars). Declare them here; set them with `wrangler secret put` and locally in
// web/.dev.vars (docs/self-hosting.md).
interface WorkerSecrets {
  /** Signs access tokens (HS256). At least 32 characters, e.g. `openssl rand -base64 48`. */
  JWT_SIGNING_KEY: string;
  /** Enables the private voyage prototype in local development and tests. */
  VOYAGE_PRIVATE_LOCAL?: string;
}

interface Env extends WorkerSecrets {}

declare namespace Cloudflare {
  interface Env extends WorkerSecrets {}
}
