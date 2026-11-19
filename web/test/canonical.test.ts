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

  it("moves the web sign-in entry point but not its callback or other API routes", () => {
    const res = canonicalRedirect(
      new Request("https://madegood.example.workers.dev/api/auth/web/apple?next=%2Fapp"),
      canonical,
    );
    expect(res?.headers.get("Location")).toBe(
      "https://madegood.app/api/auth/web/apple?next=%2Fapp",
    );
    expect(
      canonicalRedirect(
        new Request("https://madegood.example.workers.dev/api/auth/web/apple/callback", {
          method: "POST",
        }),
        canonical,
      ),
    ).toBeNull();
    expect(
      canonicalRedirect(
        new Request("https://madegood.example.workers.dev/api/auth/web/refresh"),
        canonical,
      ),
    ).toBeNull();
  });

  it("is not cacheable and leaves local development alone", () => {
    const res = canonicalRedirect(
      new Request("https://madegood.example.workers.dev/v/slug?k=secret"),
      canonical,
    );
    expect(res?.headers.get("Cache-Control")).toBe("private, no-store");
    expect(canonicalRedirect(new Request("http://localhost:8787/s/abc"), canonical)).toBeNull();
    expect(canonicalRedirect(new Request("http://127.0.0.1:8787/s/abc"), canonical)).toBeNull();
  });
});
