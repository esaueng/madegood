import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/server/app";
import { api, bearer, identityToken, type SignIn, signIn as signInWhileOn } from "./apple";

// Sharing unavailable (lib/sharing-available.ts): the production default, with SHARING unset.
// vitest.config.ts turns it on for the other tests. Synthetic data only (AGENTS.md).

const app = createApp();
const off = { ...env, SHARING: undefined };

async function request(path: string, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  const id = crypto.randomUUID();
  headers.set("CF-Connecting-IP", `2001:db8::${id.slice(0, 4)}:${id.slice(4, 8)}`);
  const ctx = createExecutionContext();
  const response = await app.request(`/api${path}`, { ...init, headers }, off, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

const send = (path: string, method: string, body: unknown, token: string) =>
  request(path, {
    method,
    headers: { ...bearer(token), "content-type": "application/json" },
    body: JSON.stringify(body),
  });

async function signIn(): Promise<SignIn> {
  const response = await request("/auth/apple", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken: await identityToken() }),
  });
  expect(response.status).toBe(200);
  return (await response.json()) as SignIn;
}

async function me(owner: SignIn) {
  const response = await request("/me", { headers: bearer(owner.accessToken) });
  expect(response.status).toBe(200);
  return (await response.json()) as {
    sharingEnabled: boolean;
    defaultVisibility: string;
    publicProfileKey: string | null;
  };
}

describe("sharing unavailable", () => {
  it("says so in the site configuration", async () => {
    const response = await request("/config");
    expect(await response.json()).toEqual({ download: null, sharing: false });
    const on = await app.request("/api/config", {}, { ...env, SHARING: "on" });
    expect(await on.json()).toEqual({ download: null, sharing: true });
  });

  it("starts new accounts with sharing off", async () => {
    const owner = await signIn();
    expect(await me(owner)).toMatchObject({
      sharingEnabled: false,
      defaultVisibility: "private",
      publicProfileKey: null,
    });
  });

  it.each([
    { sharingEnabled: true },
    { defaultVisibility: "unlisted" },
    { defaultVisibility: "public" },
    { publicProfileEnabled: true },
    { sharingEnabled: true, defaultVisibility: "public", publicProfileEnabled: true },
  ])("refuses to share through PATCH /me %j", async (body) => {
    const owner = await signIn();
    const response = await send("/me", "PATCH", body, owner.accessToken);
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: "sharing_disabled" });
    expect(await me(owner)).toMatchObject({
      sharingEnabled: false,
      defaultVisibility: "private",
      publicProfileKey: null,
    });
  });

  it("still saves settings that share nothing", async () => {
    const owner = await signIn();
    const body = { units: "metric", defaultVisibility: "private", sharingEnabled: false };
    const response = await send("/me", "PATCH", body, owner.accessToken);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ units: "metric", sharingEnabled: false });
  });

  it("refuses to make a session unlisted or public, and keeps it private to others", async () => {
    const owner = await signIn();
    const id = crypto.randomUUID();
    const meta = { sport: "kayak", startedAt: "2000-01-01T10:00:00.000Z", distanceM: 1000 };
    expect((await send(`/sessions/${id}`, "PUT", meta, owner.accessToken)).status).toBe(201);
    for (const visibility of ["unlisted", "public"]) {
      const response = await send(`/sessions/${id}`, "PATCH", { visibility }, owner.accessToken);
      expect(response.status).toBe(409);
      expect(await response.json()).toMatchObject({ error: "sharing_disabled" });
    }
    expect((await request(`/sessions/${id}`)).status).toBe(404);
    const own = await request(`/sessions/${id}`, { headers: bearer(owner.accessToken) });
    expect(await own.json()).toMatchObject({ visibility: "private" });
  });

  // Review of this change: the migration runs before the new Worker serves traffic, so an
  // old Worker can still turn an account's switch back on and share. Readers ignore that.
  it("shows nobody else what an account shared while sharing was on", async () => {
    const owner = await signInWhileOn();
    const id = crypto.randomUUID();
    const meta = { sport: "kayak", startedAt: "2000-01-02T10:00:00.000Z", distanceM: 1000 };
    const json = (method: string, body: unknown) => ({
      method,
      headers: { ...bearer(owner.accessToken), "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    expect((await api(`/sessions/${id}`, json("PUT", meta))).status).toBe(201);
    expect((await api(`/sessions/${id}`, json("PATCH", { visibility: "public" }))).status).toBe(
      200,
    );
    const profile = await api("/me", json("PATCH", { publicProfileEnabled: true }));
    const { publicProfileKey } = (await profile.json()) as { publicProfileKey: string };
    // Shared while sharing is on.
    expect((await api(`/sessions/${id}`)).status).toBe(200);
    expect((await api(`/users/${publicProfileKey}`)).status).toBe(200);

    // The same rows with sharing unavailable.
    expect((await request(`/sessions/${id}`)).status).toBe(404);
    expect((await request(`/sessions/${id}/track`)).status).toBe(404);
    expect((await request(`/users/${publicProfileKey}`)).status).toBe(404);
    const own = await request(`/sessions/${id}`, { headers: bearer(owner.accessToken) });
    expect(own.status).toBe(200);
    expect(await own.json()).toMatchObject({ visibility: "public", wind: null });
  });

  it("uploads new sessions as private while the account's switch is off", async () => {
    const owner = await signIn();
    // A non-private default left behind by an old Worker during the deploy.
    await env.DB.prepare("UPDATE users SET default_visibility = 'public' WHERE id = ?")
      .bind(owner.user.id)
      .run();
    const id = crypto.randomUUID();
    const meta = { sport: "kayak", startedAt: "2000-01-03T10:00:00.000Z", distanceM: 1000 };
    const put = await send(`/sessions/${id}`, "PUT", meta, owner.accessToken);
    expect(put.status).toBe(201);
    expect(await put.json()).toMatchObject({ visibility: "private" });
  });
});
