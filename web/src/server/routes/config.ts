import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { AppEnv } from "../app";

const Download = z.object({
  url: z.url(),
  store: z.enum(["testflight", "app-store"]),
});

function downloadLink(value: string | undefined): z.infer<typeof Download> | null {
  const url = URL.parse(value ?? "");
  if (url?.protocol !== "https:" || url.username || url.password) return null;

  switch (url.origin) {
    case "https://testflight.apple.com":
      return { url: url.href, store: "testflight" };
    case "https://apps.apple.com":
      return { url: url.href, store: "app-store" };
    default:
      return null;
  }
}

const route = createRoute({
  method: "get",
  path: "/config",
  summary: "Public website configuration",
  tags: ["meta"],
  responses: {
    200: {
      description: "The landing page's public download link, or null when unavailable.",
      content: { "application/json": { schema: z.object({ download: Download.nullable() }) } },
    },
  },
});

export const config = new OpenAPIHono<AppEnv>().openapi(route, (c) => {
  c.header("Cache-Control", "no-store");
  return c.json({ download: downloadLink(c.env.DOWNLOAD_URL) }, 200);
});
