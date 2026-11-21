import { describe, expect, it } from "vitest";
import { HANDLE_PATTERN, normalizeHandle } from "../src/shared/handle";

describe("handle validation shared by Settings and the API", () => {
  it("validates the trimmed, lowercase handle", () => {
    const handle = normalizeHandle("  Test_Paddler9  ");
    expect(handle).toBe("test_paddler9");
    expect(HANDLE_PATTERN.test(handle)).toBe(true);
  });

  it.each(["a_0", "x".repeat(30)])("accepts %s", (input) => {
    expect(HANDLE_PATTERN.test(normalizeHandle(input))).toBe(true);
  });

  it.each(["", "   ", "ab", "x".repeat(31), "with space", "with-hyphen", "étoile"])(
    "rejects %j",
    (input) => {
      expect(HANDLE_PATTERN.test(normalizeHandle(input))).toBe(false);
    },
  );
});
