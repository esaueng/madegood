import { describe, expect, it } from "vitest";
import * as entry from "../src/server/index";

// workerd treats every named export of the entry module as an entrypoint and refuses to
// start ("Incorrect type for map entry") when one is a string or other plain value.
describe("Worker entry module", () => {
  it("exports only functions, classes and handler objects", () => {
    for (const [name, value] of Object.entries(entry)) {
      const ok = typeof value === "function" || (typeof value === "object" && value !== null);
      expect(ok, `export ${name} is a ${typeof value}`).toBe(true);
    }
  });
});
