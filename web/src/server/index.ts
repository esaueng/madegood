import { drizzle } from "drizzle-orm/d1";
import { createApp } from "./app";
import { sweepAccountDeletions } from "./lib/account-deletion";
import { handleExportBatch, sweepExports } from "./lib/export-job";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";
import { collectR2Garbage, UPLOAD_GRACE_MS } from "./lib/r2-garbage";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

/** wrangler.jsonc `queues.consumers`: account exports have their own queue (batch size 1). */
export const EXPORTS_QUEUE = "madegood-exports";

/** Page requests the Worker sees (/s/*, /u/*, /v/*) and the web sign-in entry point on another
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
  queue: (batch, env) =>
    batch.queue === EXPORTS_QUEUE
      ? handleExportBatch(batch, env)
      : handlePostprocessBatch(batch, env),
  // Queues zone changes whose reprocessing could not be queued at the time; expires,
  // resumes or fails account exports (lib/export-job.ts); finishes account deletions
  // (lib/account-deletion.ts); and collects recorded R2 objects that no upload can still
  // attach (lib/r2-garbage.ts). No failure stops the others.
  scheduled: async (_controller, env, ctx) => {
    const results = await Promise.allSettled([
      sweepPendingZoneChanges(env, ctx),
      sweepExports(env, ctx),
      sweepAccountDeletions(env),
      collectR2Garbage(drizzle(env.DB), env.TRACKS, {
        before: Date.now() - UPLOAD_GRACE_MS,
        limit: 5000,
      }),
    ]);
    for (const result of results) if (result.status === "rejected") throw result.reason;
  },
} satisfies ExportedHandler<Env>;
