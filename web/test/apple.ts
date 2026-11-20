import { env, exports } from "cloudflare:workers";
import { decodeJwt, exportJWK, generateKeyPair, SignJWT } from "jose";
import { vi } from "vitest";
import { DELETION_GRACE_MS, runAccountDeletion } from "../src/server/lib/account-deletion";
import { steadyWest } from "./weatherkit";

// A stand-in for Apple's signing key. The Worker fetches the "Apple" JWKS from a mocked
// fetch, so tests never reach appleid.apple.com.
export const KID = "test-apple-key";
export const appleKey = await generateKeyPair("RS256", { extractable: true });
/** Another key published under the same key ID, to forge a bad signature. */
export const forgerKey = await generateKeyPair("RS256", { extractable: true });

const jwks = {
  keys: [{ ...(await exportJWK(appleKey.publicKey)), kid: KID, alg: "RS256", use: "sig" }],
};

const realFetch = globalThis.fetch;
export const jwksRequests: string[] = [];
export const weatherKitRequests: URL[] = [];
vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
  const url = input instanceof Request ? input.url : String(input);
  if (url === "https://appleid.apple.com/auth/keys") {
    jwksRequests.push(url);
    return Response.json(jwks);
  }
  if (new URL(url).hostname === "weatherkit.apple.com") {
    const request = new URL(url);
    weatherKitRequests.push(request);
    return steadyWest(request);
  }
  return realFetch(input, init);
});

export const AUDIENCE = "app.madegood";

type IdentityTokenOptions = {
  sub?: string;
  aud?: string;
  iss?: string;
  expiresAt?: number;
  key?: CryptoKey;
  nonce?: string;
};

/** Signs an identity token shaped like Apple's. Times are epoch seconds. */
export function identityToken(options: IdentityTokenOptions = {}) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({
    email_verified: true,
    ...(options.nonce === undefined ? {} : { nonce: options.nonce }),
  })
    .setProtectedHeader({ alg: "RS256", kid: KID })
    .setIssuer(options.iss ?? "https://appleid.apple.com")
    .setAudience(options.aud ?? AUDIENCE)
    .setSubject(options.sub ?? `001234.${crypto.randomUUID().replaceAll("-", "")}.0001`)
    .setIssuedAt(now - 60)
    .setExpirationTime(options.expiresAt ?? now + 600)
    .sign(options.key ?? appleKey.privateKey);
}

export const api = (path: string, init?: RequestInit) => {
  const headers = new Headers(init?.headers);
  if (path.startsWith("/auth/") && !headers.has("CF-Connecting-IP")) {
    // workerd tests have no Cloudflare ingress. Keep unrelated auth tests from sharing a
    // budget, while allowing rate-limit tests to give a sequence of requests the same IP.
    const id = crypto.randomUUID();
    headers.set("CF-Connecting-IP", `2001:db8::${id.slice(0, 4)}:${id.slice(4, 8)}`);
  }
  return exports.default.fetch(`https://madegood.test/api${path}`, { ...init, headers });
};

export const postJson = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  api(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });

export type SignIn = {
  accessToken: string;
  refreshToken: string;
  user: { id: string; handle: string; displayName: string | null };
};

export async function signIn(body: { identityToken?: string; displayName?: string } = {}) {
  const response = await postJson("/auth/apple", {
    identityToken: body.identityToken ?? (await identityToken()),
    ...(body.displayName ? { displayName: body.displayName } : {}),
  });
  if (response.status !== 200) throw new Error(`sign-in failed: ${response.status}`);
  return (await response.json()) as SignIn;
}

export const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

/**
 * DELETE /me for the token's own account, then (unless `finish` is false) runs the deletion
 * job past its grace period, as the scheduled sweep would.
 */
export async function deleteMe(
  auth: string | Record<string, string>,
  options: { finish?: boolean; userId?: string } = {},
) {
  const headers = typeof auth === "string" ? bearer(auth) : auth;
  const token = (headers.authorization ?? "").replace(/^Bearer /i, "");
  const userId = options.userId ?? String(decodeJwt(token).sub);
  const response = await api("/me", {
    method: "DELETE",
    headers: { ...headers, "content-type": "application/json" },
    body: JSON.stringify({ userId }),
  });
  if ((options.finish ?? true) && response.status === 202) {
    await runAccountDeletion(env, String(decodeJwt(token).sub), Date.now() + DELETION_GRACE_MS + 1);
  }
  return response;
}
