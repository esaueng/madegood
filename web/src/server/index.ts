import { createApp } from "./app";
import { handlePostprocessBatch } from "./lib/postprocess";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

export default {
  fetch: app.fetch,
  queue: (batch, env) => handlePostprocessBatch(batch, env),
} satisfies ExportedHandler<Env>;
