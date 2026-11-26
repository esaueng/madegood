import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/server/app";

const app = createApp();

describe("GET /api/config", () => {
  it("serves the default without a download link or a cacheable response", async () => {
    const response = await exports.default.fetch("https://madegood.test/api/config");
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ download: null, sharing: true });
  });

  it.each([
    ["https://testflight.apple.com/join/example", "testflight"],
    ["https://apps.apple.com/us/app/example/id0000000000", "app-store"],
  ])("serves the configured link %s for %s", async (url, store) => {
    const response = await app.request("/api/config", {}, { ...env, DOWNLOAD_URL: url });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ download: { url, store }, sharing: true });
  });

  it.each([
    "",
    "not a URL",
    "https://example.com/download",
    "https://testflight.apple.com.example.com/join/example",
    "http://apps.apple.com/us/app/example",
    "blob:https://apps.apple.com/example",
    "https://example.com@apps.apple.com/app/example",
    "https://apps.apple.com:8443/app/example",
  ])("returns no download link for %j", async (value) => {
    const response = await app.request("/api/config", {}, { ...env, DOWNLOAD_URL: value });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ download: null, sharing: true });
  });
});
