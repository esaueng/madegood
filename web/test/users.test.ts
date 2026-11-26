import { createExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { profileSettingsChanges } from "../src/client/lib/profile-settings";
import { createApp } from "../src/server/app";
import { profilePreviewPage } from "../src/server/routes/session-preview";
import { api, bearer, deleteMe, identityToken, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.

const json = (method: string, body: unknown, token: string) => ({
  method,
  headers: { ...bearer(token), "content-type": "application/json" },
  body: JSON.stringify(body),
});

const setProfile = (owner: SignIn, changes: Record<string, unknown>) =>
  api("/me", json("PATCH", changes, owner.accessToken));

async function profileKeyOf(response: Response): Promise<string> {
  expect(response.status).toBe(200);
  const { publicProfileKey } = (await response.json()) as { publicProfileKey: string };
  expect(publicProfileKey).toEqual(expect.any(String));
  return publicProfileKey;
}

async function profileUser(displayName: string | null = "Test Skipper") {
  const user = await signIn({ displayName: displayName ?? undefined });
  const profileKey = await profileKeyOf(
    await setProfile(user, { publicProfileEnabled: true, publicProfileDisplayName: displayName }),
  );
  return { ...user, profileKey };
}

let minute = 0;
/** A session with the given visibility; each one starts a minute after the last. */
async function addSession(
  owner: SignIn,
  visibility: "private" | "unlisted" | "public",
  overrides: Record<string, unknown> = {},
) {
  const id = crypto.randomUUID();
  const startedAt = new Date(Date.UTC(2000, 0, 1, 10, minute++)).toISOString();
  const meta = {
    sport: "kayak",
    startedAt,
    durationS: 600,
    movingS: 500,
    distanceM: 1000,
    maxSpeedMps: 3,
    avgSpeedMps: 2,
    summary: { distance: 1000, heartRateMax: 150, start: { lat: 0.0001, lon: 0.0002 } },
    ...overrides,
  };
  expect((await api(`/sessions/${id}`, json("PUT", meta, owner.accessToken))).status).toBe(201);
  const patch = json(
    "PATCH",
    { visibility, title: `${visibility} trip`, notes: "secret note" },
    owner.accessToken,
  );
  expect((await api(`/sessions/${id}`, patch)).status).toBe(200);
  return id;
}

const getProfile = (key: string, token?: string, query = "") =>
  api(`/users/${encodeURIComponent(key)}${query}`, { headers: token ? bearer(token) : {} });

type Profile = {
  displayName: string | null;
  isOwner: boolean;
  totals: { sessions: number; distanceM: number; bySport: { sport: string; sessions: number }[] };
  sessions: { id: string; title: string | null }[];
  nextCursor: string | null;
};

async function profileOf(key: string, token?: string, query = ""): Promise<Profile> {
  const response = await getProfile(key, token, query);
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("private, no-store");
  return response.json();
}

describe("GET /api/users/:profileKey", () => {
  it("requires opt-in and revokes the opaque link without altering session visibility", async () => {
    const owner = await signIn({ displayName: "Test Skipper" });
    const id = await addSession(owner, "public");
    const me = await api("/me", { headers: bearer(owner.accessToken) });
    expect(await me.json()).toMatchObject({ publicProfileKey: null });
    expect((await getProfile(owner.user.handle, owner.accessToken)).status).toBe(404);

    const enable = () => setProfile(owner, { publicProfileEnabled: true });
    const first = await profileKeyOf(await enable());
    expect(first).not.toBe(owner.user.id);
    expect(await profileKeyOf(await enable())).toBe(first);
    expect((await profileOf(first)).sessions.map((session) => session.id)).toEqual([id]);
    expect((await getProfile(owner.user.handle)).status).toBe(404);

    const disabled = await setProfile(owner, { publicProfileEnabled: false });
    expect(await disabled.json()).toMatchObject({ publicProfileKey: null });
    expect((await getProfile(first)).status).toBe(404);
    expect((await getProfile(first, owner.accessToken)).status).toBe(404);
    expect((await api(`/sessions/${id}`)).status).toBe(200);

    const second = await profileKeyOf(await enable());
    expect(second).not.toBe(first);
    expect((await getProfile(first)).status).toBe(404);
    expect((await getProfile(second)).status).toBe(200);
  });

  it("uses a custom URL only when explicitly chosen and keeps the display name independent", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    const username = owner.user.handle;
    const custom = await profileKeyOf(
      await setProfile(owner, {
        publicProfileUsername: username.toUpperCase(),
        publicProfileDisplayName: "Chosen Name",
      }),
    );
    expect(custom).toBe(`@${username}~${owner.profileKey}`);
    expect((await profileOf(custom)).displayName).toBe("Chosen Name");
    expect((await getProfile(`@${username}`)).status).toBe(404);
    expect((await getProfile(username)).status).toBe(404);
    expect((await getProfile(owner.profileKey)).status).toBe(404);

    const other = await signIn();
    expect((await setProfile(other, { publicProfileUsername: username })).status).toBe(409);
    expect((await setProfile(other, { publicProfileUsername: "admin" })).status).toBe(409);

    expect((await setProfile(owner, { publicProfileEnabled: false })).status).toBe(200);
    expect((await getProfile(custom, owner.accessToken)).status).toBe(404);
    expect((await getProfile(custom)).status).toBe(404);
    expect((await setProfile(other, { publicProfileUsername: username })).status).toBe(409);
    const disabled = await setProfile(owner, { publicProfileUsername: null });
    expect(await disabled.json()).toMatchObject({
      publicProfileKey: null,
      publicProfileUsername: null,
    });
    const reassigned = await profileKeyOf(
      await setProfile(other, { publicProfileEnabled: true, publicProfileUsername: username }),
    );
    await addSession(other, "public");
    expect((await getProfile(reassigned)).status).toBe(200);
    expect((await getProfile(custom)).status).toBe(404);
    const opaque = await profileKeyOf(await setProfile(owner, { publicProfileEnabled: true }));
    expect(opaque).not.toBe(custom);
    expect((await getProfile(custom)).status).toBe(404);
    expect((await profileOf(opaque)).displayName).toBe("Chosen Name");
  });

  it("keeps an explicitly cleared account name blank when Apple supplies a name again", async () => {
    const sub = crypto.randomUUID();
    const owner = await signIn({
      identityToken: await identityToken({ sub }),
      displayName: "Test Skipper",
    });
    await addSession(owner, "public");
    const key = await profileKeyOf(
      await setProfile(owner, { displayName: null, publicProfileEnabled: true }),
    );
    const signedInAgain = await signIn({
      identityToken: await identityToken({ sub }),
      displayName: "Test Skipper",
    });
    expect(signedInAgain.user.displayName).toBeNull();
    expect((await profileOf(key)).displayName).toBeNull();
  });

  it("can fill an account name from Apple without publishing it on an enabled profile", async () => {
    const sub = crypto.randomUUID();
    const owner = await signIn({ identityToken: await identityToken({ sub }) });
    await addSession(owner, "public");
    const key = await profileKeyOf(await setProfile(owner, { publicProfileEnabled: true }));
    const signedInAgain = await signIn({
      identityToken: await identityToken({ sub }),
      displayName: "Test Skipper",
    });
    expect(signedInAgain.user.displayName).toBe("Test Skipper");
    expect((await profileOf(key)).displayName).toBeNull();
  });

  it("a stale username-only edit cannot restore a cleared profile name", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    const nameWithTrailingSpace = `${"A".repeat(49)} `;
    await env.DB.prepare("UPDATE users SET public_profile_display_name = ? WHERE id = ?")
      .bind(nameWithTrailingSpace, owner.user.id)
      .run();
    const stale = {
      publicProfileDisplayName: nameWithTrailingSpace,
      publicProfileUsername: null,
    };
    expect((await setProfile(owner, { publicProfileDisplayName: null })).status).toBe(200);

    const fields = new FormData();
    fields.set("displayName", stale.publicProfileDisplayName);
    fields.set("username", owner.user.handle);
    const key = await profileKeyOf(
      await setProfile(owner, profileSettingsChanges(stale, fields, false)),
    );
    expect((await profileOf(key)).displayName).toBeNull();
  });

  it("shows the display name, public totals and public sessions", async () => {
    const owner = await profileUser("Anne <Sailor>");
    const a = await addSession(owner, "public", { sport: "sailing", distanceM: 2000 });
    const b = await addSession(owner, "public");
    const profile = await profileOf(owner.profileKey);
    expect(profile).toMatchObject({
      displayName: "Anne <Sailor>",
      isOwner: false,
      nextCursor: null,
    });
    expect(profile.sessions.map((s) => s.id)).toEqual([b, a]);
    expect(profile.totals).toEqual({
      sessions: 2,
      distanceM: 3000,
      movingS: 1000,
      durationS: 1200,
      bySport: [
        { sport: "kayak", sessions: 1, distanceM: 1000, movingS: 500, durationS: 600 },
        { sport: "sailing", sessions: 1, distanceM: 2000, movingS: 500, durationS: 600 },
      ],
    });
    // Either case finds the same profile.
    expect(await profileOf(owner.profileKey.toUpperCase())).toEqual(profile);
  });

  it("never lists or counts private or unlisted sessions", async () => {
    const owner = await profileUser();
    const shown = await addSession(owner, "public");
    const hidden = [
      await addSession(owner, "private"),
      await addSession(owner, "unlisted"),
      await addSession(owner, "private", { sport: "sup" }),
    ];
    for (const token of [undefined, (await signIn()).accessToken, owner.accessToken]) {
      const profile = await profileOf(owner.profileKey, token);
      expect(profile.sessions.map((s) => s.id)).toEqual([shown]);
      expect(profile.totals.sessions).toBe(1);
      expect(profile.totals.bySport.map((s) => s.sport)).toEqual(["kayak"]);
      const text = JSON.stringify(profile);
      for (const id of hidden) expect(text).not.toContain(id);
      expect(text).not.toContain("private trip");
      expect(text).not.toContain("unlisted trip");
    }

    // Making it private again takes it off at once; so does deleting it.
    await api(`/sessions/${shown}`, json("PATCH", { visibility: "unlisted" }, owner.accessToken));
    expect((await getProfile(owner.profileKey)).status).toBe(404);
    const again = await addSession(owner, "public");
    await api(`/sessions/${again}`, { method: "DELETE", headers: bearer(owner.accessToken) });
    expect((await getProfile(owner.profileKey)).status).toBe(404);
  });

  it("returns no positions, notes, summaries or account details", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    // A zone over the whole area: nothing about where the session was may appear.
    await api(
      "/me/privacy-zones",
      json("POST", { lat: 0, lon: 0, radiusM: 5000 }, owner.accessToken),
    );
    for (const token of [undefined, owner.accessToken]) {
      const response = await getProfile(owner.profileKey, token);
      const text = await response.text();
      const profile = JSON.parse(text) as Record<string, unknown>;
      expect(Object.keys(profile).sort()).toEqual(
        ["displayName", "isOwner", "nextCursor", "sessions", "totals"].sort(),
      );
      const [session] = profile.sessions as Record<string, unknown>[];
      expect(Object.keys(session ?? {}).sort()).toEqual(
        [
          "avgSpeedMps",
          "distanceM",
          "durationS",
          "id",
          "maxSpeedMps",
          "movingS",
          "sport",
          "startedAt",
          "title",
        ].sort(),
      );
      expect(text).not.toMatch(/lat|lon|bounds|notes|secret|summary|heartRate|units|visibility/i);
      expect(text).not.toContain(owner.user.id);
      expect(text).not.toContain(owner.user.handle);
    }
  });

  it("is not found for unknown keys and legacy handles", async () => {
    for (const handle of ["nobody_here_123", "x", "a-b", "admin", "%F0%9F%9B%B6"]) {
      const response = await getProfile(handle);
      expect(response.status, handle).toBe(404);
      expect(await response.json()).toEqual({ error: "not_found", message: "No such profile." });
    }
  });

  it("hides a profile with no public sessions from everyone but its owner", async () => {
    const owner = await profileUser("Quiet Person");
    await addSession(owner, "private");
    await addSession(owner, "unlisted");
    const other = await signIn();
    for (const token of [undefined, other.accessToken]) {
      const response = await getProfile(owner.profileKey, token);
      expect(response.status).toBe(404);
      // The same answer as for a handle nobody has: no name, nothing to tell them apart.
      expect(await response.json()).toEqual({ error: "not_found", message: "No such profile." });
    }
    const own = await profileOf(owner.profileKey, owner.accessToken);
    expect(own).toEqual({
      displayName: "Quiet Person",
      isOwner: true,
      totals: { sessions: 0, distanceM: 0, movingS: 0, durationS: 0, bySport: [] },
      sessions: [],
      nextCursor: null,
    });
  });

  it("does the same database work for an unknown key as for a hidden profile", async () => {
    // Regression (PR #95 review): a second query only for existing accounts made a timing
    // signal for which handles exist. Every request now reads in one batch.
    const hidden = await profileUser("Never Shared");
    await addSession(hidden, "private");
    const trace = async (handle: string) => {
      const calls: string[] = [];
      const DB = new Proxy(env.DB, {
        get(target, key) {
          const value = Reflect.get(target, key, target);
          if (typeof value !== "function") return value;
          return (...args: unknown[]) => {
            calls.push(key === "batch" ? `batch:${(args[0] as unknown[]).length}` : String(key));
            return value.apply(target, args);
          };
        },
      });
      const bindings = {
        DB,
        TRACKS: env.TRACKS,
        JWT_SIGNING_KEY: env.JWT_SIGNING_KEY,
        APPLE_AUDIENCES: env.APPLE_AUDIENCES,
        SHARING: env.SHARING,
      };
      const response = await createApp().request(
        `/api/users/${handle}`,
        {},
        bindings,
        createExecutionContext(),
      );
      expect(response.status).toBe(404);
      return calls;
    };
    const unknown = await trace(crypto.randomUUID());
    expect(unknown.filter((call) => call.startsWith("batch"))).toEqual(["batch:3"]);
    expect(await trace(hidden.profileKey)).toEqual(unknown);
  });

  it("is not found once the account is being deleted", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    expect((await getProfile(owner.profileKey)).status).toBe(200);
    expect((await deleteMe(owner.accessToken, { finish: false })).status).toBe(202);
    expect((await getProfile(owner.profileKey)).status).toBe(404);
  });

  it("pages newest first with a cursor, totals covering every page", async () => {
    const owner = await profileUser();
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push(await addSession(owner, "public"));
    await addSession(owner, "private");
    const newestFirst = ids.reverse();

    const first = await profileOf(owner.profileKey, undefined, "?limit=2");
    expect(first.sessions.map((s) => s.id)).toEqual(newestFirst.slice(0, 2));
    expect(first.totals.sessions).toBe(5);
    expect(first.nextCursor).not.toBeNull();
    const second = await profileOf(
      owner.profileKey,
      undefined,
      `?limit=2&cursor=${first.nextCursor}`,
    );
    expect(second.sessions.map((s) => s.id)).toEqual(newestFirst.slice(2, 4));
    const last = await profileOf(
      owner.profileKey,
      undefined,
      `?limit=2&cursor=${second.nextCursor}`,
    );
    expect(last.sessions.map((s) => s.id)).toEqual(newestFirst.slice(4));
    expect(last.nextCursor).toBeNull();

    expect((await getProfile(owner.profileKey, undefined, "?cursor=nope")).status).toBe(400);
    expect((await getProfile(owner.profileKey, undefined, "?limit=51")).status).toBe(400);
  });

  it("answers 401 to an invalid token, so the client can refresh it", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    expect((await getProfile(owner.profileKey, "not-a-token")).status).toBe(401);
  });
});

describe("Open Graph tags on /u/:profileKey", () => {
  const SHELL =
    '<!doctype html><html><head><meta name="description" content="Default" /><title>MadeGood</title></head><body><div id="root"></div></body></html>';
  const assets = {
    fetch: async () => new Response(SHELL, { headers: { "content-type": "text/html" } }),
  };
  const page = async (key: string) => {
    const response = await profilePreviewPage.request(
      `https://madegood.test/u/${key}`,
      {},
      { ...env, ASSETS: assets },
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    return response.text();
  };

  it("previews an enabled profile with its name, public count and distance", async () => {
    const owner = await profileUser("Anne <Sailor>");
    await addSession(owner, "public", { distanceM: 1852 });
    await addSession(owner, "public", { distanceM: 1852 });
    await addSession(owner, "private", { distanceM: 100_000 });
    const html = await page(owner.profileKey.toUpperCase());
    const name = "Anne &lt;Sailor&gt;";
    expect(html).toContain(`<title>${name} · MadeGood</title>`);
    expect(html).toContain(`property="og:title" content="${name}"`);
    // The owner's default units are nautical; the private session is not counted.
    expect(html).toContain(
      'property="og:description" content="2 public sessions · 2.00 nm on MadeGood"',
    );
    expect(html).toContain('name="robots" content="index, follow"');
    expect(html).toContain('<div id="root"></div>');
  });

  it("uses a generic title without a display name", async () => {
    const owner = await profileUser(null);
    await addSession(owner, "public");
    expect(await page(owner.profileKey)).toContain(
      'property="og:title" content="A profile on MadeGood"',
    );
  });

  it("hides personal data and URLs on unavailable profile pages", async () => {
    const quiet = await profileUser("Quiet Person");
    await addSession(quiet, "private");
    await addSession(quiet, "unlisted");
    const leaving = await profileUser("Leaving Person");
    await addSession(leaving, "public");
    await deleteMe(leaving.accessToken, { finish: false });
    const pages = await Promise.all(
      [quiet.profileKey, leaving.profileKey, crypto.randomUUID(), leaving.user.handle, "a-b"].map(
        (h) => page(h),
      ),
    );
    for (const html of pages) {
      expect(html).toContain("<title>A profile on MadeGood</title>");
      expect(html).not.toContain("Person");
      expect(html).toContain('name="robots" content="noindex"');
    }
    expect(new Set(pages).size).toBe(1);
  });

  it("removes the chosen name and URL from previews as soon as the profile is disabled", async () => {
    const owner = await profileUser("Test Skipper");
    await addSession(owner, "public");
    const key = await profileKeyOf(
      await setProfile(owner, { publicProfileUsername: owner.user.handle }),
    );
    expect(await page(key)).toContain('property="og:title" content="Test Skipper"');
    expect((await setProfile(owner, { publicProfileEnabled: false })).status).toBe(200);
    const html = await page(key);
    expect(html).toBe(await page(crypto.randomUUID()));
    expect(html).not.toContain(key);
    expect(html).not.toContain("Test Skipper");
  });
});
