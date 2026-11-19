import { createApp } from "./app";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

/** Page requests the Worker sees (/s/*, /v/*) and the web sign-in entry point on another
 * host move to CANONICAL_ORIGIN, so Apple gets the registered return URL and cookies land on
 * the canonical host. The rest of the API keeps answering on every host: older app builds sync
 * to the workers.dev address, and a redirect would turn their uploads into GETs. Local hosts
 * (wrangler dev) are left alone. */
const SIGN_IN_ENTRY = "/api/auth/web/apple";
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

export function canonicalRedirect(
  request: Request,
  canonical: string | undefined,
): Response | null {
  if (!canonical || (request.method !== "GET" && request.method !== "HEAD")) return null;
  const url = new URL(request.url);
  if (url.origin === canonical || LOCAL_HOSTS.has(url.hostname)) return null;
  const isApi = url.pathname === "/api" || url.pathname.startsWith("/api/");
  if (isApi && url.pathname !== SIGN_IN_ENTRY) return null;
  // Not cacheable: /v/* query strings carry share credentials that can be revoked.
  return new Response(null, {
    status: 301,
    headers: {
      Location: `${canonical}${url.pathname}${url.search}`,
      "Cache-Control": "private, no-store",
    },
  });
}

export default {
  fetch: (request, env, ctx) =>
    canonicalRedirect(request, env.CANONICAL_ORIGIN) ?? app.fetch(request, env, ctx),
  queue: (batch, env) => handlePostprocessBatch(batch, env),
  // Queues zone changes whose reprocessing could not be queued at the time.
  scheduled: async (_controller, env, ctx) => {
    await sweepPendingZoneChanges(env, ctx);
  },
} satisfies ExportedHandler<Env>;
