import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

describe("GET /api/health", () => {
  it("reports ok when the database is reachable", async () => {
    const response = await exports.default.fetch("https://madegood.test/api/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok", version: "0.1.0", db: "ok" });
  });
});

describe("API routing", () => {
  it("returns a JSON 404 for unknown API paths", async () => {
    const response = await exports.default.fetch("https://madegood.test/api/nope");
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "not_found" });
  });

  it("serves an OpenAPI document whose operations resolve to working URLs", async () => {
    const response = await exports.default.fetch("https://madegood.test/api/openapi.json");
    expect(response.status).toBe(200);
    const doc = (await response.json()) as {
      openapi: string;
      servers: { url: string }[];
      paths: Record<string, unknown>;
    };
    expect(doc.openapi).toBe("3.1.0");
    expect(Object.keys(doc.paths)).toContain("/health");

    // A generated client joins the server URL and the path; that URL must work.
    const base = doc.servers[0]?.url ?? "";
    const resolved = new URL(`${base}/health`, "https://madegood.test");
    const health = await exports.default.fetch(resolved.toString());
    expect(health.status).toBe(200);
  });
});
