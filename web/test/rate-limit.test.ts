import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import { api, bearer, identityToken, postJson, signIn } from "./apple";

async function expectLimited(response: Response) {
  expect(response.status).toBe(429);
  expect(response.headers.get("retry-after")).toBe("60");
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(await response.json()).toMatchObject({ error: "rate_limited" });
}

it("shares an IP budget across app and web sign-in and refresh", async () => {
  const account = await signIn();
  const token = await identityToken();
  const ip = "192.0.2.10";
  const headers = { "CF-Connecting-IP": ip };

  // Spend all but one request in this local binding's window without minting test tokens.
  expect(await env.AUTH_RATE_LIMIT.limit({ key: ip, delta: 59 })).toEqual({ success: true });
  expect((await api("/auth/web/refresh", { method: "POST", headers })).status).toBe(403);
  const started = await api("/auth/web/apple", { headers, redirect: "manual" });
  expect(started.status).toBe(302);

  await expectLimited(await postJson("/auth/apple", { identityToken: token }, headers));
  const refresh = { refreshToken: account.refreshToken };
  await expectLimited(await postJson("/auth/refresh", refresh, headers));
  await expectLimited(await api("/auth/web/apple", { headers, redirect: "manual" }));
  await expectLimited(await api("/auth/web/apple/callback", { method: "POST", headers }));
  await expectLimited(
    await api("/auth/web/refresh", {
      method: "POST",
      headers: { ...headers, Origin: "https://madegood.test" },
    }),
  );
  await expectLimited(
    await postJson("/auth/apple", "{", { ...headers, "X-Forwarded-For": "192.0.2.12" }),
  );

  // A different IP still has its own budget and the throttled refresh did not rotate the token.
  const allowed = await postJson("/auth/refresh", refresh, { "CF-Connecting-IP": "192.0.2.11" });
  expect(allowed.status).toBe(200);
});

it("shares an upload budget by authenticated account across metadata and track PUTs", async () => {
  const owner = await signIn();
  const other = await signIn();
  const id = crypto.randomUUID();
  const path = `/sessions/${id}`;
  const metadata = (token: string, ip: string, sessionPath = path) =>
    api(sessionPath, {
      method: "PUT",
      headers: {
        ...bearer(token),
        "content-type": "application/json",
        "CF-Connecting-IP": ip,
      },
      body: JSON.stringify({
        sport: "kayak",
        startedAt: "2000-01-01T10:00:00.000Z",
        analyzerVersion: "1.0.0",
      }),
    });

  expect(await env.SESSION_UPLOAD_RATE_LIMIT.limit({ key: owner.user.id, delta: 1199 })).toEqual({
    success: true,
  });
  expect((await metadata("invalid", "192.0.2.20")).status).toBe(401);
  expect((await metadata(owner.accessToken, "192.0.2.20")).status).toBe(201);

  await expectLimited(
    await api(`${path}/track`, {
      method: "PUT",
      headers: { ...bearer(owner.accessToken), "CF-Connecting-IP": "192.0.2.21" },
    }),
  );
  await expectLimited(await metadata(owner.accessToken, "192.0.2.21"));
  expect((await api(path, { headers: bearer(owner.accessToken) })).status).toBe(200);
  expect(
    (await metadata(other.accessToken, "192.0.2.20", `/sessions/${crypto.randomUUID()}`)).status,
  ).toBe(201);
});
