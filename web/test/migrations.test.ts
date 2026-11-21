import { applyD1Migrations } from "cloudflare:test";
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

describe("D1 migrations: sessions, tokens, privacy zones", () => {
  const insertSession = (id: string, userId: string) =>
    env.DB.prepare(
      "insert into sessions (id, user_id, sport, started_at) values (?, ?, 'kayak', ?)",
    )
      .bind(id, userId, 1_800_000_000_000)
      .run();

  it("make sessions private by default", async () => {
    await insertUser("u20", "sub-20", "bosun");
    await insertSession("s20", "u20");
    const row = await env.DB.prepare("select visibility, updated_at from sessions where id = ?")
      .bind("s20")
      .first<{ visibility: string; updated_at: number }>();
    expect(row?.visibility).toBe("private");
    expect(row?.updated_at).toBeGreaterThan(1_700_000_000_000);
  });

  it("delete a user's sessions, tokens and zones with the user", async () => {
    await insertUser("u30", "sub-30", "purser");
    await insertSession("s30", "u30");
    await env.DB.prepare(
      "insert into refresh_tokens (id, user_id, token_hash, expires_at) values (?, ?, ?, ?)",
    )
      .bind("t30", "u30", "hash-30", 1_900_000_000_000)
      .run();
    await env.DB.prepare(
      "insert into privacy_zones (id, user_id, lat, lon, radius_m) values (?, ?, 0, 0, 200)",
    )
      .bind("z30", "u30")
      .run();
    await env.DB.prepare("delete from users where id = ?").bind("u30").run();
    for (const table of ["sessions", "refresh_tokens", "privacy_zones"]) {
      const row = await env.DB.prepare(`select count(*) as n from ${table} where user_id = ?`)
        .bind("u30")
        .first<{ n: number }>();
      expect(row?.n, table).toBe(0);
    }
  });

  it("clears stored wind and keeps existing accounts opted out during rollout", async () => {
    const db = env.TEST_MIGRATION_DB;
    const name = "0013_clear_stored_wind.sql";
    await applyD1Migrations(
      db,
      env.TEST_MIGRATIONS.filter((migration) => migration.name < name),
    );
    await db.batch([
      db.prepare(
        "INSERT INTO users (id, apple_sub, handle) VALUES ('u50', 'sub-50', 'wind-test-owner')",
      ),
      db.prepare(`INSERT INTO sessions (id, user_id, sport, started_at, visibility, wind_json)
        VALUES ('s50', 'u50', 'kayak', 1, 'public', '{"source":"open-meteo-archive"}'),
               ('s51', 'u50', 'kayak', 1, 'private', NULL)`),
    ]);
    await applyD1Migrations(db, env.TEST_MIGRATIONS);
    // The previous queue consumer may still finish a pending wind update during deployment.
    await db.prepare("UPDATE sessions SET wind_json = '{}' WHERE id = 's51'").run();
    const { results } = await db
      .prepare("SELECT id, visibility, wind_json FROM sessions ORDER BY id")
      .all();
    expect(results).toEqual([
      { id: "s50", visibility: "public", wind_json: null },
      { id: "s51", visibility: "private", wind_json: null },
    ]);
    expect(
      await db
        .prepare("SELECT public_profile_id, public_profile_username FROM users WHERE id = 'u50'")
        .first(),
    ).toEqual({ public_profile_id: null, public_profile_username: null });
  });

  it("reject a session for an unknown user and a reused token hash", async () => {
    await expect(insertSession("s40", "nobody")).rejects.toThrow(/FOREIGN KEY/);
    await insertUser("u41", "sub-41", "cook");
    const insertToken = (id: string) =>
      env.DB.prepare(
        "insert into refresh_tokens (id, user_id, token_hash, expires_at) values (?, 'u41', 'same', 1)",
      )
        .bind(id)
        .run();
    await insertToken("t41");
    await expect(insertToken("t42")).rejects.toThrow(/UNIQUE/);
  });
});
