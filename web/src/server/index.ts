import { drizzle } from "drizzle-orm/d1";
import { createApp } from "./app";
import { sweepAccountDeletions } from "./lib/account-deletion";
import { handlePostprocessBatch, sweepPendingZoneChanges } from "./lib/postprocess";
import { collectR2Garbage, UPLOAD_GRACE_MS } from "./lib/r2-garbage";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

export default {
  fetch: app.fetch,
  queue: (batch, env) => handlePostprocessBatch(batch, env),
  // Queues zone changes whose reprocessing could not be queued at the time, finishes
  // account deletions (lib/account-deletion.ts) and collects recorded R2 objects that no
  // upload can still attach (lib/r2-garbage.ts). No failure stops the others.
  scheduled: async (_controller, env, ctx) => {
    const results = await Promise.allSettled([
      sweepPendingZoneChanges(env, ctx),
      sweepAccountDeletions(env),
      collectR2Garbage(drizzle(env.DB), env.TRACKS, {
        before: Date.now() - UPLOAD_GRACE_MS,
        limit: 5000,
      }),
    ]);
    for (const result of results) if (result.status === "rejected") throw result.reason;
  },
} satisfies ExportedHandler<Env>;
