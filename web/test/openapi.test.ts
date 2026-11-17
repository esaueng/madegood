import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import committed from "../../openapi/openapi.json";

describe("openapi/openapi.json", () => {
  it("matches the API's own description (run scripts/generate-openapi)", async () => {
    const response = await exports.default.fetch("https://madegood.test/api/openapi.json");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(committed);
  });
});
