import { createApp } from "./app";

export { VoyageLive } from "./live/voyage-live";

const app = createApp();

export default {
  fetch: app.fetch,
} satisfies ExportedHandler<Env>;
