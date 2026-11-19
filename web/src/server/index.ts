import { createApp } from "./app";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

export default {
  fetch: app.fetch,
  queue: (batch, env) => handlePostprocessBatch(batch, env),
  // Queues zone changes whose reprocessing could not be queued at the time.
  scheduled: async (_controller, env, ctx) => {
    await sweepPendingZoneChanges(env, ctx);
  },
} satisfies ExportedHandler<Env>;
