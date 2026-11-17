import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { AppEnv } from "../app";

const Health = z
  .object({
    status: z.enum(["ok", "degraded"]),
    version: z.string(),
    db: z.enum(["ok", "error"]),
  })
  .openapi("Health");

const route = createRoute({
  method: "get",
  path: "/health",
  summary: "Service health",
  tags: ["meta"],
  responses: {
    200: {
      description: "The API and its database are reachable.",
      content: { "application/json": { schema: Health } },
    },
    503: {
      description: "The database is unreachable.",
      content: { "application/json": { schema: Health } },
    },
  },
});

export const health = new OpenAPIHono<AppEnv>().openapi(route, async (c) => {
  let db: "ok" | "error" = "ok";
  try {
    await c.env.DB.prepare("select 1").first();
  } catch {
    db = "error";
  }
  const body = { status: db === "ok" ? "ok" : "degraded", version: c.env.APP_VERSION, db } as const;
  return db === "ok" ? c.json(body, 200) : c.json(body, 503);
});
