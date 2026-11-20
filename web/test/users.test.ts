import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { profilePreviewPage } from "../src/server/routes/session-preview";
import { api, bearer, deleteMe, type SignIn, signIn } from "./apple";

// Synthetic data only (AGENTS.md): positions near 0,0 and dates in 2000.

const json = (method: string, body: unknown, token: string) => ({
  method,
  headers: { ...bearer(token), "content-type": "application/json" },
  body: JSON.stringify(body),
});

const uniqueHandle = () => `p_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;

/** A signed-in user with a known handle and display name. */
async function profileUser(displayName: string | null = "Test Skipper") {
  const user = await signIn();
  const handle = uniqueHandle();
  const response = await api("/me", json("PATCH", { handle, displayName }, user.accessToken));
  expect(response.status).toBe(200);
  return { ...user, handle };
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

const getProfile = (handle: string, token?: string, query = "") =>
  api(`/users/${handle}${query}`, { headers: token ? bearer(token) : {} });

type Profile = {
  handle: string;
  displayName: string | null;
  isOwner: boolean;
  totals: { sessions: number; distanceM: number; bySport: { sport: string; sessions: number }[] };
  sessions: { id: string; title: string | null }[];
  nextCursor: string | null;
};

async function profileOf(handle: string, token?: string, query = ""): Promise<Profile> {
  const response = await getProfile(handle, token, query);
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("private, no-cache");
  return response.json();
}

describe("GET /api/users/:handle", () => {
  it("shows the handle, display name, public totals and public sessions", async () => {
    const owner = await profileUser("Anne <Sailor>");
    const a = await addSession(owner, "public", { sport: "sailing", distanceM: 2000 });
    const b = await addSession(owner, "public");
    const profile = await profileOf(owner.handle);
    expect(profile).toMatchObject({
      handle: owner.handle,
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
    expect((await profileOf(owner.handle.toUpperCase())).handle).toBe(owner.handle);
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
      const profile = await profileOf(owner.handle, token);
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
    expect((await getProfile(owner.handle)).status).toBe(404);
    const again = await addSession(owner, "public");
    await api(`/sessions/${again}`, { method: "DELETE", headers: bearer(owner.accessToken) });
    expect((await getProfile(owner.handle)).status).toBe(404);
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
      const response = await getProfile(owner.handle, token);
      const text = await response.text();
      const profile = JSON.parse(text) as Record<string, unknown>;
      expect(Object.keys(profile).sort()).toEqual(
        ["displayName", "handle", "isOwner", "nextCursor", "sessions", "totals"].sort(),
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
    }
  });

  it("is not found for unknown, malformed or reserved handles", async () => {
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
      const response = await getProfile(owner.handle, token);
      expect(response.status).toBe(404);
      // The same answer as for a handle nobody has: no name, nothing to tell them apart.
      expect(await response.json()).toEqual({ error: "not_found", message: "No such profile." });
    }
    const own = await profileOf(owner.handle, owner.accessToken);
    expect(own).toEqual({
      handle: owner.handle,
      displayName: "Quiet Person",
      isOwner: true,
      totals: { sessions: 0, distanceM: 0, movingS: 0, durationS: 0, bySport: [] },
      sessions: [],
      nextCursor: null,
    });
  });

  it("is not found once the account is being deleted", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    expect((await getProfile(owner.handle)).status).toBe(200);
    expect((await deleteMe(owner.accessToken, { finish: false })).status).toBe(202);
    expect((await getProfile(owner.handle)).status).toBe(404);
  });

  it("pages newest first with a cursor, totals covering every page", async () => {
    const owner = await profileUser();
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push(await addSession(owner, "public"));
    await addSession(owner, "private");
    const newestFirst = ids.reverse();

    const first = await profileOf(owner.handle, undefined, "?limit=2");
    expect(first.sessions.map((s) => s.id)).toEqual(newestFirst.slice(0, 2));
    expect(first.totals.sessions).toBe(5);
    expect(first.nextCursor).not.toBeNull();
    const second = await profileOf(owner.handle, undefined, `?limit=2&cursor=${first.nextCursor}`);
    expect(second.sessions.map((s) => s.id)).toEqual(newestFirst.slice(2, 4));
    const last = await profileOf(owner.handle, undefined, `?limit=2&cursor=${second.nextCursor}`);
    expect(last.sessions.map((s) => s.id)).toEqual(newestFirst.slice(4));
    expect(last.nextCursor).toBeNull();

    expect((await getProfile(owner.handle, undefined, "?cursor=nope")).status).toBe(400);
    expect((await getProfile(owner.handle, undefined, "?limit=51")).status).toBe(400);
  });

  it("answers 401 to an invalid token, so the client can refresh it", async () => {
    const owner = await profileUser();
    await addSession(owner, "public");
    expect((await getProfile(owner.handle, "not-a-token")).status).toBe(401);
  });
});

describe("Open Graph tags on /u/:handle", () => {
  const SHELL =
    '<!doctype html><html><head><meta name="description" content="Default" /><title>MadeGood</title></head><body><div id="root"></div></body></html>';
  const assets = {
    fetch: async () => new Response(SHELL, { headers: { "content-type": "text/html" } }),
  };
  const page = async (handle: string) => {
    const response = await profilePreviewPage.request(
      `https://madegood.test/u/${handle}`,
      {},
      { ...env, ASSETS: assets },
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-cache");
    return response.text();
  };

  it("previews a profile with public sessions: name, handle, count and distance", async () => {
    const owner = await profileUser("Anne <Sailor>");
    await addSession(owner, "public", { distanceM: 1852 });
    await addSession(owner, "public", { distanceM: 1852 });
    await addSession(owner, "private", { distanceM: 100_000 });
    const html = await page(owner.handle.toUpperCase());
    const name = `Anne &lt;Sailor&gt; (@${owner.handle})`;
    expect(html).toContain(`<title>${name} · MadeGood</title>`);
    expect(html).toContain(`property="og:title" content="${name}"`);
    // The owner's default units are nautical; the private session is not counted.
    expect(html).toContain(
      'property="og:description" content="2 public sessions · 2.00 nm on MadeGood"',
    );
    expect(html).toContain('name="robots" content="index, follow"');
    expect(html).toContain('<div id="root"></div>');
  });

  it("uses the handle alone without a display name", async () => {
    const owner = await profileUser(null);
    await addSession(owner, "public");
    expect(await page(owner.handle)).toContain(`property="og:title" content="@${owner.handle}"`);
  });

  it("never names a user without public sessions, or tells them from unknown handles", async () => {
    const quiet = await profileUser("Quiet Person");
    await addSession(quiet, "private");
    await addSession(quiet, "unlisted");
    const leaving = await profileUser("Leaving Person");
    await addSession(leaving, "public");
    await deleteMe(leaving.accessToken, { finish: false });
    const pages = await Promise.all(
      [quiet.handle, leaving.handle, "nobody_here_123", "a-b"].map((h) => page(h)),
    );
    for (const html of pages) {
      expect(html).toContain("<title>A profile on MadeGood</title>");
      expect(html).not.toContain("Person");
      expect(html).toContain('name="robots" content="noindex"');
    }
    const normalized = pages.map((html) => html.replace(/\/u\/[^"]+/g, "/u/HANDLE"));
    expect(new Set(normalized).size).toBe(1);
  });
});
