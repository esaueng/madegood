import { createApp } from "./app";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

/** Page requests the Worker sees (/s/*, /v/*) on another host move to CANONICAL_ORIGIN.
 * The API keeps answering on every host: older app builds sync to the workers.dev address,
 * and a redirect would turn their uploads into GETs. */
export function canonicalRedirect(
  request: Request,
  canonical: string | undefined,
): Response | null {
  if (!canonical || (request.method !== "GET" && request.method !== "HEAD")) return null;
  const url = new URL(request.url);
  if (url.origin === canonical || url.pathname === "/api" || url.pathname.startsWith("/api/"))
    return null;
  return Response.redirect(`${canonical}${url.pathname}${url.search}`, 301);
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
