import { OpenAPIHono } from "@hono/zod-openapi";
import { health } from "./routes/health";

export type AppEnv = { Bindings: Env };

export function createApp() {
  const api = new OpenAPIHono<AppEnv>();

  api.route("/", health);

  // Paths in the document are relative to the `/api` server, where `api` is mounted.
  api.doc31("/openapi.json", {
    openapi: "3.1.0",
    info: { title: "MadeGood API", version: "1" },
    servers: [{ url: "/api" }],
  });

  const app = new OpenAPIHono<AppEnv>().route("/api", api);

  // Hono only consults the root app's handlers, so these live here, not on `api`.
  // The Worker only sees /api/* (wrangler.jsonc `run_worker_first`); everything else
  // is served as static assets with the SPA fallback.
  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((err, c) => {
    console.error(err);
    return c.json({ error: "internal" }, 500);
  });

  return app;
}
