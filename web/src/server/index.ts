import { createApp } from "./app";
import { handleExportBatch, sweepExports } from "./lib/export-job";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

/** wrangler.jsonc `queues.consumers`: account exports have their own queue (batch size 1). */
export const EXPORTS_QUEUE = "madegood-exports";

export default {
  fetch: app.fetch,
  queue: (batch, env) =>
    batch.queue === EXPORTS_QUEUE
      ? handleExportBatch(batch, env)
      : handlePostprocessBatch(batch, env),
  // Queues zone changes whose reprocessing could not be queued at the time, and expires,
  // resumes or fails account exports (lib/export-job.ts). Neither failure stops the other.
  scheduled: async (_controller, env, ctx) => {
    const results = await Promise.allSettled([
      sweepPendingZoneChanges(env, ctx),
      sweepExports(env, ctx),
    ]);
    for (const result of results) if (result.status === "rejected") throw result.reason;
  },
} satisfies ExportedHandler<Env>;
