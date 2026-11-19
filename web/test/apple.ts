import { exports } from "cloudflare:workers";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { vi } from "vitest";
import { openMeteo } from "./open-meteo";

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
/** The hosts lib/wind.ts calls; answered by the stand-in in test/open-meteo.ts. */
const OPEN_METEO_HOSTS = new Set(["api.open-meteo.com", "archive-api.open-meteo.com"]);
export const jwksRequests: string[] = [];
vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
  const url = input instanceof Request ? input.url : String(input);
  if (url === "https://appleid.apple.com/auth/keys") {
    jwksRequests.push(url);
    return Response.json(jwks);
  }
  if (OPEN_METEO_HOSTS.has(new URL(url).hostname)) return openMeteo(new URL(url));
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

export const api = (path: string, init?: RequestInit) =>
  exports.default.fetch(`https://madegood.test/api${path}`, init);

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
