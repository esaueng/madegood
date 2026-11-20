import { OpenAPIHono } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";
import { apiError } from "./lib/errors";
import { auth } from "./routes/auth";
import { exportRoutes } from "./routes/exports";
import { health } from "./routes/health";
import { me } from "./routes/me";
import { privacyZoneRoutes } from "./routes/privacy-zones";
import { profilePreviewPage, sessionPreviewPage } from "./routes/session-preview";
import { sessionRoutes } from "./routes/sessions";
import { userRoutes } from "./routes/users";
import { voyageLiveRoutes, voyageViewerPage } from "./routes/voyage-live";
import { voyageRoutes } from "./routes/voyages";
import { webAuth } from "./routes/web-auth";

export type AppEnv = { Bindings: Env };

export function createApp() {
  const api = new OpenAPIHono<AppEnv>();

  api.route("/", health);
  api.route("/", auth);
  api.route("/", me);
  api.route("/", exportRoutes);
  api.route("/", privacyZoneRoutes);
  api.route("/", sessionRoutes);
  api.route("/", userRoutes);
  api.route("/", voyageLiveRoutes);
  api.route("/", voyageRoutes);
  // Plain Hono routes: browser redirects and cookies, left out of the OpenAPI document.
  api.route("/", webAuth);

  api.openAPIRegistry.registerComponent("securitySchemes", "bearerAuth", {
    type: "http",
    scheme: "bearer",
    bearerFormat: "JWT",
    description: "Access token from POST /auth/apple or POST /auth/refresh.",
  });

  // Paths in the document are relative to the `/api` server, where `api` is mounted.
  api.doc31("/openapi.json", {
    openapi: "3.1.0",
    info: { title: "MadeGood API", version: "1" },
    servers: [{ url: "/api" }],
  });

  const app = new OpenAPIHono<AppEnv>()
    .route("/api", api)
    .route("/", voyageViewerPage)
    .route("/", sessionPreviewPage)
    .route("/", profilePreviewPage);

  // Hono only consults the root app's handlers, so these live here, not on `api`.
  // The Worker handles /api/*, /v/*, /s/* and /u/* (wrangler.jsonc `run_worker_first`); everything else
  // is served as static assets with the SPA fallback.
  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((err, c) => {
    // Hono raises these for client errors such as a malformed JSON body.
    if (err instanceof HTTPException && err.status === 400) {
      return apiError(c, 400, "invalid_request", err.message);
    }
    if (err instanceof HTTPException && err.status < 500) return err.getResponse();
    console.error(err);
    return apiError(c, 500, "internal");
  });

  return app;
}
