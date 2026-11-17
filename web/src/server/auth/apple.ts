import { createRemoteJWKSet, errors, jwtVerify } from "jose";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

// Module scope, so the key set is cached per isolate across requests. jose refetches
// after `cacheMaxAge`, or sooner when a token names a key ID it has not seen (Apple
// rotating keys), at most once per `cooldownDuration`.
let appleKeys: ReturnType<typeof createRemoteJWKSet> | undefined;
function getAppleKeys() {
  appleKeys ??= createRemoteJWKSet(new URL(APPLE_JWKS_URL), {
    cacheMaxAge: 60 * 60 * 1000,
    cooldownDuration: 30 * 1000,
    timeoutDuration: 5000,
  });
  return appleKeys;
}

/** `APPLE_AUDIENCES` is comma-separated: the app's bundle ID, later the web Services ID. */
export function parseAudiences(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

const tokenErrors = [
  errors.JWTExpired,
  errors.JWTClaimValidationFailed,
  errors.JWTInvalid,
  errors.JWSInvalid,
  errors.JWSSignatureVerificationFailed,
  errors.JWKSNoMatchingKey,
  errors.JWKSMultipleMatchingKeys,
  errors.JOSEAlgNotAllowed,
  errors.JOSENotSupported,
];

export class InvalidIdentityToken extends Error {}

/**
 * Verifies a Sign in with Apple identity token: Apple's signature (RS256), issuer,
 * audience and expiry. Returns Apple's stable user identifier (`sub`).
 */
export async function verifyAppleIdentityToken(
  token: string,
  audiences: string[],
): Promise<{ sub: string }> {
  if (audiences.length === 0) throw new Error("APPLE_AUDIENCES is not configured");
  try {
    const { payload } = await jwtVerify(token, getAppleKeys(), {
      issuer: APPLE_ISSUER,
      audience: audiences,
      algorithms: ["RS256"],
      requiredClaims: ["sub", "exp", "iat"],
    });
    if (typeof payload.sub !== "string" || payload.sub === "") {
      throw new InvalidIdentityToken("missing subject");
    }
    return { sub: payload.sub };
  } catch (err) {
    if (err instanceof InvalidIdentityToken) throw err;
    // Bad tokens are the client's problem (401). Failing to fetch or parse Apple's keys
    // is ours, so those errors propagate as a 500.
    if (tokenErrors.some((type) => err instanceof type)) {
      throw new InvalidIdentityToken((err as errors.JOSEError).code);
    }
    throw err;
  }
}
