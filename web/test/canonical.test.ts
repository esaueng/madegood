import { describe, expect, it } from "vitest";
import { canonicalRedirect } from "../src/server/index";

const canonical = "https://madegood.app";

describe("canonical origin redirect", () => {
  it("moves pages on another host to the canonical address, keeping path and query", () => {
    const res = canonicalRedirect(
      new Request("https://madegood.example.workers.dev/s/abc?x=1"),
      canonical,
    );
    expect(res?.status).toBe(301);
    expect(res?.headers.get("Location")).toBe("https://madegood.app/s/abc?x=1");
  });

  it("leaves the API, the canonical host, writes and unconfigured environments alone", () => {
    expect(
      canonicalRedirect(new Request("https://madegood.example.workers.dev/api/health"), canonical),
    ).toBeNull();
    expect(
      canonicalRedirect(new Request("https://madegood.example.workers.dev/api"), canonical),
    ).toBeNull();
    expect(canonicalRedirect(new Request("https://madegood.app/s/abc"), canonical)).toBeNull();
    expect(
      canonicalRedirect(
        new Request("https://madegood.example.workers.dev/s/abc", { method: "POST" }),
        canonical,
      ),
    ).toBeNull();
    expect(canonicalRedirect(new Request("https://pr-1.example.workers.dev/s/abc"), "")).toBeNull();
  });
});
