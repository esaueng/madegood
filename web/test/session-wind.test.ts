import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/server/app";
import { bearer, signIn, weatherKitRequests } from "./apple";
import { steadyWest } from "./weatherkit";

const start = Date.parse("2022-01-02T10:12:00Z");
const app = createApp();

async function seed(
  userId: string,
  lat: number,
  visibility: "public" | "unlisted" | "private" = "public",
  startMs = start,
) {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO sessions (id, user_id, sport, started_at, visibility, track_key, track_etag,
       processed_etag, postprocess_status, public_min_lat, public_min_lon, public_max_lat,
       public_max_lon, public_track_started_at, public_track_ended_at, public_zones_version)
     VALUES (?, ?, 'kayak', ?, ?, ?, 'track-etag', 'track-etag', 'done', ?, 0, ?, 0, ?, ?, 0)`,
  )
    .bind(id, userId, startMs, visibility, `synthetic/${id}`, lat, lat, startMs, startMs + 60_000)
    .run();
  return id;
}

function view(id: string, bindings = env, token?: string) {
  return app.fetch(
    new Request(`https://madegood.test/api/sessions/${id}`, {
      headers: token ? bearer(token) : {},
    }),
    bindings,
    createExecutionContext(),
  );
}

describe("wind on session detail views", () => {
  it.each([
    ["public", 0.123],
    ["unlisted", 0.223],
  ] as const)(
    "looks up %s wind and reuses it for the same cell and hours",
    async (visibility, lat) => {
      const owner = await signIn();
      const id = await seed(owner.user.id, lat, visibility);
      const other = await seed(owner.user.id, lat + 0.01, visibility, start + 60_000);
      const before = weatherKitRequests.length;
      const prepare = vi.fn((query: string) => env.DB.prepare(query));
      const r2 = vi.fn();
      const bindings = {
        ...env,
        DB: { prepare } as unknown as D1Database,
        TRACKS: new Proxy(env.TRACKS, { get: r2 }),
      };
      const first = await view(id, bindings);
      expect(first.status).toBe(200);
      expect(first.headers.get("cache-control")).toBe("private, no-store");
      const body = await first.json<{ wind: unknown }>();
      expect(body.wind).toMatchObject({ source: "weatherkit", directionDeg: 270, speedMps: 5 });
      expect(await (await view(`${id}?cacheBust=1&hourlyStart=anything`, bindings)).json()).toEqual(
        body,
      );
      expect(await (await view(other, bindings)).json()).toMatchObject({ wind: body.wind });
      expect(await (await view(id, bindings, owner.accessToken)).json()).toMatchObject({
        isOwner: true,
        wind: body.wind,
      });
      const requests = weatherKitRequests.slice(before);
      expect(requests).toHaveLength(1);
      expect(requests[0]?.pathname).toBe(`/api/v1/weather/en/${lat.toFixed(1)}/0`);
      expect(prepare).toHaveBeenCalled();
      expect(prepare.mock.calls.every(([sql]) => /^select\b/i.test(sql))).toBe(true);
      expect(r2).not.toHaveBeenCalled();
      expect(
        await env.DB.prepare("SELECT wind_json FROM sessions WHERE id = ?").bind(id).first(),
      ).toEqual({ wind_json: null });
    },
  );

  it("skips private, deleted, stale-zone and account-deleting sessions", async () => {
    const owner = await signIn();
    const privateId = await seed(owner.user.id, 0.3, "private");
    const deletedId = await seed(owner.user.id, 0.3);
    const staleId = await seed(owner.user.id, 0.3);
    await env.DB.batch([
      env.DB.prepare("UPDATE sessions SET deleted_at = ? WHERE id = ?").bind(start, deletedId),
      env.DB.prepare("UPDATE sessions SET public_zones_version = NULL WHERE id = ?").bind(staleId),
    ]);
    const before = weatherKitRequests.length;
    expect((await view(privateId)).status).toBe(404);
    expect(await (await view(privateId, env, owner.accessToken)).json()).toMatchObject({
      wind: null,
    });
    expect((await view(deletedId)).status).toBe(404);
    expect(await (await view(staleId)).json()).toMatchObject({ wind: null });
    expect(await (await view(staleId, env, owner.accessToken)).json()).toMatchObject({
      wind: null,
    });

    const sharedId = await seed(owner.user.id, 0.3);
    await env.DB.prepare("UPDATE users SET deleted_at = ? WHERE id = ?")
      .bind(start, owner.user.id)
      .run();
    expect((await view(sharedId)).status).toBe(404);
    expect(weatherKitRequests).toHaveLength(before);
  });

  it("omits wind when a secret is missing, even if the cache has it", async () => {
    const owner = await signIn();
    const id = await seed(owner.user.id, 0.4);
    const unconfigured = { ...env, WEATHERKIT_SERVICE_ID: undefined };
    const before = weatherKitRequests.length;
    expect(await (await view(id, unconfigured)).json()).toMatchObject({ wind: null });
    expect(weatherKitRequests).toHaveLength(before);
    expect(await (await view(id)).json()).toMatchObject({ wind: { source: "weatherkit" } });
    expect(await (await view(id, unconfigured)).json()).toMatchObject({ wind: null });
    expect(weatherKitRequests).toHaveLength(before + 1);
  });

  it("omits wind and backs off repeat views during an upstream failure", async () => {
    const owner = await signIn();
    const id = await seed(owner.user.id, 0.5);
    const outage = vi.fn<typeof fetch>(async () => new Response(null, { status: 503 }));
    await vi.mocked(fetch).withImplementation(outage, async () => {
      for (const query of ["", "?cacheBust=1"]) {
        const response = await view(`${id}${query}`);
        expect(response.status).toBe(200);
        expect(await response.json()).toMatchObject({ wind: null });
      }
      expect(outage).toHaveBeenCalledOnce();
    });
  });

  it("limits misses across hour ranges in the same cell and across cells", async () => {
    const owner = await signIn();
    const first = await seed(owner.user.id, 0.6);
    const sameCell = await seed(owner.user.id, 0.61, "public", start + 3_600_000);
    const otherCell = await seed(owner.user.id, 0.7);
    const cell = vi
      .fn()
      .mockResolvedValueOnce({ success: true })
      .mockResolvedValueOnce({ success: false })
      .mockResolvedValueOnce({ success: true });
    const budget = vi
      .fn()
      .mockResolvedValueOnce({ success: true })
      .mockResolvedValueOnce({ success: false });
    const bindings = {
      ...env,
      WEATHERKIT_CELL_LIMIT: { limit: cell },
      WEATHERKIT_MISS_LIMIT: { limit: budget },
    };
    const before = weatherKitRequests.length;
    expect(await (await view(first, bindings)).json()).toMatchObject({
      wind: { source: "weatherkit" },
    });
    expect(await (await view(sameCell, bindings)).json()).toMatchObject({ wind: null });
    expect(await (await view(otherCell, bindings)).json()).toMatchObject({ wind: null });
    expect(cell.mock.calls).toEqual([
      [{ key: "/0.6/0" }],
      [{ key: "/0.6/0" }],
      [{ key: "/0.7/0" }],
    ]);
    expect(budget.mock.calls).toEqual([[{ key: "shared-wind" }], [{ key: "shared-wind" }]]);
    expect(weatherKitRequests).toHaveLength(before + 1);
  });

  it("rechecks visibility just before sending data to Apple", async () => {
    const owner = await signIn();
    const id = await seed(owner.user.id, 0.8);
    const before = weatherKitRequests.length;
    const response = await view(id, {
      ...env,
      WEATHERKIT_CELL_LIMIT: {
        limit: async () => {
          await env.DB.prepare("UPDATE sessions SET visibility = 'private' WHERE id = ?")
            .bind(id)
            .run();
          return { success: true };
        },
      },
    });
    expect(response.status).toBe(404);
    expect(weatherKitRequests).toHaveLength(before);
  });

  it("omits an in-flight result when the account changes its privacy zones", async () => {
    const owner = await signIn();
    const id = await seed(owner.user.id, 0.9);
    const duringFetch = vi.fn<typeof fetch>(async (input) => {
      await env.DB.prepare("UPDATE users SET zones_version = 1 WHERE id = ?")
        .bind(owner.user.id)
        .run();
      return steadyWest(new URL(String(input)));
    });
    await vi.mocked(fetch).withImplementation(duringFetch, async () => {
      const response = await view(id, {
        ...env,
        WEATHERKIT_MISS_LIMIT: { limit: async () => ({ success: true }) },
      });
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ wind: null, bounds: null });
      expect(duringFetch).toHaveBeenCalledOnce();
    });
  });
});
