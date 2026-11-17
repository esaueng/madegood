import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const insertUser = (id: string, sub: string, handle: string) =>
  env.DB.prepare("insert into users (id, apple_sub, handle) values (?, ?, ?)")
    .bind(id, sub, handle)
    .run();

describe("D1 migrations", () => {
  it("create the users table with private-by-default settings", async () => {
    await insertUser("u1", "sub-1", "skipper");
    const row = await env.DB.prepare(
      "select units, default_visibility, created_at from users where id = ?",
    )
      .bind("u1")
      .first<{ units: string; default_visibility: string; created_at: number }>();
    expect(row?.units).toBe("nautical");
    expect(row?.default_visibility).toBe("private");
    expect(row?.created_at).toBeGreaterThan(1_700_000_000_000);
  });

  it("enforce unique handles and Apple subjects", async () => {
    // Storage is shared within a test file, so use IDs no other test uses.
    await insertUser("u10", "sub-10", "navigator");
    await expect(insertUser("u11", "sub-11", "navigator")).rejects.toThrow(/UNIQUE/);
    await expect(insertUser("u12", "sub-10", "helmsman")).rejects.toThrow(/UNIQUE/);
  });
});
