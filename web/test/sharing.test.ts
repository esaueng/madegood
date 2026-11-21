import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { locateShare } from "../src/server/live/registry";
import { profilePreview, sessionPreview } from "../src/server/routes/session-preview";
import { api, bearer, type SignIn, signIn } from "./apple";

// The account-wide sharing switch (users.sharing_enabled) and the shared-sessions list.
// Synthetic data only (AGENTS.md): dates in 2000, no positions.

type Visibility = "private" | "unlisted" | "public";

const json = (method: string, body: unknown, token: string) => ({
  method,
  headers: { ...bearer(token), "content-type": "application/json" },
  body: JSON.stringify(body),
});

const patchMe = (owner: SignIn, body: unknown) =>
  api("/me", json("PATCH", body, owner.accessToken));

const setVisibility = (owner: SignIn, id: string, visibility: Visibility) =>
  api(`/sessions/${id}`, json("PATCH", { visibility }, owner.accessToken));

let minute = 0;
async function addSession(owner: SignIn, visibility: Visibility) {
  const id = crypto.randomUUID();
  const meta = {
    sport: "kayak",
    startedAt: new Date(Date.UTC(2000, 0, 1, 10, minute++)).toISOString(),
    distanceM: 1000,
  };
  expect((await api(`/sessions/${id}`, json("PUT", meta, owner.accessToken))).status).toBe(201);
  expect((await setVisibility(owner, id, visibility)).status).toBe(200);
  return id;
}

async function sharedIds(owner: SignIn, query = "?shared=true") {
  const response = await api(`/sessions${query}`, { headers: bearer(owner.accessToken) });
  expect(response.status).toBe(200);
  const body = (await response.json()) as { sessions: { id: string; visibility: string }[] };
  return body.sessions;
}

async function withHandle() {
  const owner = await signIn();
  const handle = `s_${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
  expect((await patchMe(owner, { handle })).status).toBe(200);
  return { ...owner, handle };
}

describe("GET /api/sessions?shared=", () => {
  it("lists only the sessions others can see, or only private ones", async () => {
    const owner = await signIn();
    const priv = await addSession(owner, "private");
    const unlisted = await addSession(owner, "unlisted");
    const pub = await addSession(owner, "public");
    // Someone else's shared session never shows up.
    await addSession(await signIn(), "public");

    const shared = await sharedIds(owner);
    expect(shared.map((s) => s.id)).toEqual([pub, unlisted]);
    expect(shared.map((s) => s.visibility)).toEqual(["public", "unlisted"]);
    expect((await sharedIds(owner, "?shared=false")).map((s) => s.id)).toEqual([priv]);
  });

  it("rejects other values", async () => {
    const owner = await signIn();
    const response = await api("/sessions?shared=yes", { headers: bearer(owner.accessToken) });
    expect(response.status).toBe(400);
  });
});

describe("turning sharing off", () => {
  it("is on by default", async () => {
    const owner = await signIn();
    const me = await api("/me", { headers: bearer(owner.accessToken) });
    expect(await me.json()).toMatchObject({ sharingEnabled: true });
  });

  it("makes every session private and hides them from everyone else", async () => {
    const owner = await withHandle();
    const unlisted = await addSession(owner, "unlisted");
    const pub = await addSession(owner, "public");
    expect((await patchMe(owner, { defaultVisibility: "public" })).status).toBe(200);
    const viewer = await signIn();
    expect((await api(`/sessions/${pub}`)).status).toBe(200);
    expect((await api(`/users/${owner.handle}`)).status).toBe(200);

    const off = await patchMe(owner, { sharingEnabled: false });
    expect(off.status).toBe(200);
    expect(await off.json()).toMatchObject({ sharingEnabled: false, defaultVisibility: "private" });

    expect(await sharedIds(owner)).toEqual([]);
    for (const id of [unlisted, pub]) {
      expect((await api(`/sessions/${id}`)).status).toBe(404);
      expect((await api(`/sessions/${id}`, { headers: bearer(viewer.accessToken) })).status).toBe(
        404,
      );
      expect((await api(`/sessions/${id}/track`)).status).toBe(404);
      expect((await sessionPreview(env.DB, id)).indexable).toBe(false);
      expect((await sessionPreview(env.DB, id)).title).toBe("A session on MadeGood");
      // The owner still sees their own.
      const own = await api(`/sessions/${id}`, { headers: bearer(owner.accessToken) });
      expect(await own.json()).toMatchObject({ id, visibility: "private" });
    }
    expect((await api(`/users/${owner.handle}`)).status).toBe(404);
    expect((await profilePreview(env.DB, owner.handle)).title).toBe("A profile on MadeGood");

    // New uploads stay private.
    const later = crypto.randomUUID();
    const put = await api(
      `/sessions/${later}`,
      json("PUT", { sport: "sup", startedAt: "2000-01-02T10:00:00Z" }, owner.accessToken),
    );
    expect(await put.json()).toMatchObject({ visibility: "private" });
  });

  it("refuses to share anything until it is turned back on", async () => {
    const owner = await signIn();
    const id = await addSession(owner, "private");
    expect((await patchMe(owner, { sharingEnabled: false })).status).toBe(200);

    for (const visibility of ["unlisted", "public"] as const) {
      const response = await setVisibility(owner, id, visibility);
      expect(response.status, visibility).toBe(409);
      expect(await response.json()).toMatchObject({ error: "sharing_disabled" });
      const defaults = await patchMe(owner, { defaultVisibility: visibility });
      expect(defaults.status, visibility).toBe(409);
      expect(await defaults.json()).toMatchObject({ error: "sharing_disabled" });
    }
    // Private stays allowed, and so do other edits.
    expect((await setVisibility(owner, id, "private")).status).toBe(200);
    expect(
      (await api(`/sessions/${id}`, json("PATCH", { title: "x" }, owner.accessToken))).status,
    ).toBe(200);
    expect((await patchMe(owner, { defaultVisibility: "private" })).status).toBe(200);
    // A contradictory request is refused whole.
    const both = await patchMe(owner, { sharingEnabled: false, defaultVisibility: "public" });
    expect(both.status).toBe(409);

    // Turning it on shares nothing by itself; the session can then be shared again.
    const on = await patchMe(owner, { sharingEnabled: true });
    expect(await on.json()).toMatchObject({ sharingEnabled: true, defaultVisibility: "private" });
    expect(await sharedIds(owner)).toEqual([]);
    expect((await setVisibility(owner, id, "unlisted")).status).toBe(200);
    expect((await api(`/sessions/${id}`)).status).toBe(200);
    // Turning it on and choosing a shared default in one request works.
    expect((await patchMe(owner, { sharingEnabled: false })).status).toBe(200);
    const again = await patchMe(owner, { sharingEnabled: true, defaultVisibility: "unlisted" });
    expect(await again.json()).toMatchObject({
      sharingEnabled: true,
      defaultVisibility: "unlisted",
    });
  });

  it("leaves other accounts' sessions alone", async () => {
    const owner = await signIn();
    const other = await signIn();
    const theirs = await addSession(other, "public");
    await addSession(owner, "public");
    expect((await patchMe(owner, { sharingEnabled: false })).status).toBe(200);
    expect((await api(`/sessions/${theirs}`)).status).toBe(200);
  });

  it("hides a session readers would otherwise see, even if it were still shared", async () => {
    // Defense in depth: the readers check the switch, not only visibility.
    const owner = await withHandle();
    const id = await addSession(owner, "public");
    await env.DB.prepare("UPDATE users SET sharing_enabled = 0 WHERE id = ?")
      .bind(owner.user.id)
      .run();
    expect((await api(`/sessions/${id}`)).status).toBe(404);
    expect((await api(`/sessions/${id}/track`)).status).toBe(404);
    expect((await api(`/users/${owner.handle}`)).status).toBe(404);
    expect((await sessionPreview(env.DB, id)).indexable).toBe(false);
  });

  it("stops live voyage links from resolving", async () => {
    const owner = await signIn();
    const voyageId = crypto.randomUUID();
    const slugHash = `hash-${crypto.randomUUID()}`;
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO voyages (user_id, id, title, started_at) VALUES (?, ?, 'Passage', 946720800000)",
      ).bind(owner.user.id, voyageId),
      env.DB.prepare(
        "INSERT INTO voyage_live_registry (user_id, voyage_id, generation, slug_hash) VALUES (?, ?, 1, ?)",
      ).bind(owner.user.id, voyageId, slugHash),
    ]);
    expect(await locateShare(env.DB, slugHash)).toEqual({ userId: owner.user.id, voyageId });
    expect((await patchMe(owner, { sharingEnabled: false })).status).toBe(200);
    expect(await locateShare(env.DB, slugHash)).toBeNull();
  });
});
