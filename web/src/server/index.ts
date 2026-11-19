import { createApp } from "./app";
import { sweepAccountDeletions } from "./lib/account-deletion";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

export default {
  fetch: app.fetch,
  queue: (batch, env) => handlePostprocessBatch(batch, env),
  // Queues zone changes whose reprocessing could not be queued at the time, and finishes
  // account deletions (lib/account-deletion.ts). Neither failure stops the other.
  scheduled: async (_controller, env, ctx) => {
    const results = await Promise.allSettled([
      sweepPendingZoneChanges(env, ctx),
      sweepAccountDeletions(env),
    ]);
    for (const result of results) if (result.status === "rejected") throw result.reason;
  },
} satisfies ExportedHandler<Env>;
