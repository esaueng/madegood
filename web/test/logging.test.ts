import { describe, expect, it, vi } from "vitest";
import { logFailure } from "../src/server/lib/logging";

describe("Worker console logging", () => {
  it("discards all fields of thrown errors and non-Error values", () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const cause = {
      body: { appleSubject: "synthetic-apple-subject", email: "test@example.invalid" },
      authorization: "Bearer synthetic-token",
      coordinates: [0, 0],
    };
    const failure = Object.assign(
      new Error("Failed query: params: synthetic-account-id, synthetic-session-id", { cause }),
      {
        name: "synthetic-handle",
        stack: "synthetic-display-name",
        toJSON() {
          throw new Error("Logger tried to serialize a raw error");
        },
      },
    );
    try {
      logFailure("request_failed", failure);
      logFailure("account_deletion_retry", cause);
      expect(error.mock.calls).toEqual([[{ event: "request_failed" }]]);
      expect(warn.mock.calls).toEqual([[{ event: "account_deletion_retry" }]]);
    } finally {
      error.mockRestore();
      warn.mockRestore();
    }
  });
});
