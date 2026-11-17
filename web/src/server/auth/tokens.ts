import { and, eq, isNull } from "drizzle-orm";
import type { DrizzleD1Database } from "drizzle-orm/d1";
import { jwtVerify, SignJWT } from "jose";
import { refreshTokens } from "../db/schema";

export const ACCESS_TOKEN_TTL_S = 15 * 60;
export const REFRESH_TOKEN_TTL_MS = 60 * 24 * 60 * 60 * 1000;

const ISSUER = "madegood";
const AUDIENCE = "madegood-api";
// Header `typ` per RFC 9068, so an access token can't be mistaken for any other JWT we
// might later sign with the same key.
const TYP = "at+jwt";

// HS256 (a shared secret) rather than an asymmetric algorithm: this Worker is both the
// only issuer and the only verifier of access tokens, so nothing else ever needs a public
// key. A single secret is simpler to provision (one Wrangler secret) and to rotate
// (change it; outstanding access tokens expire within 15 minutes and clients refresh).
// Switch to ES256 with a published JWKS if another service ever has to verify them.
function signingKey(secret: string | undefined): Uint8Array {
  // 32 bytes matches HS256's 256-bit output; shorter keys are brute-forceable.
  if (!secret || secret.length < 32) {
    throw new Error("JWT_SIGNING_KEY is missing or shorter than 32 characters");
  }
  return new TextEncoder().encode(secret);
}

export async function signAccessToken(userId: string, secret: string | undefined) {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256", typ: TYP })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TOKEN_TTL_S}s`)
    .sign(signingKey(secret));
}

/** Returns the user ID, or null for any invalid, expired or foreign token. */
export async function verifyAccessToken(
  token: string,
  secret: string | undefined,
): Promise<string | null> {
  const key = signingKey(secret);
  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: ISSUER,
      audience: AUDIENCE,
      algorithms: ["HS256"],
      typ: TYP,
      requiredClaims: ["sub", "exp"],
    });
    return typeof payload.sub === "string" && payload.sub !== "" ? payload.sub : null;
  } catch {
    return null;
  }
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");

export async function hashRefreshToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

type Db = DrizzleD1Database<Record<string, unknown>>;

/** Creates a random 256-bit refresh token; only its SHA-256 hash is stored. */
export async function issueRefreshToken(db: Db, userId: string, now = Date.now()) {
  const token = base64url(crypto.getRandomValues(new Uint8Array(32)));
  await db.insert(refreshTokens).values({
    id: crypto.randomUUID(),
    userId,
    tokenHash: await hashRefreshToken(token),
    expiresAt: now + REFRESH_TOKEN_TTL_MS,
    createdAt: now,
  });
  return token;
}

export async function issueTokenPair(db: Db, userId: string, secret: string | undefined) {
  const accessToken = await signAccessToken(userId, secret);
  const refreshToken = await issueRefreshToken(db, userId);
  return { accessToken, refreshToken };
}

export type RotateResult =
  | { ok: true; userId: string; refreshToken: string }
  | { ok: false; reason: "invalid" | "reused" };

/**
 * Exchanges a refresh token for a new one. Each token works once. Presenting a token that
 * was already used (or revoked) means it leaked or a client is replaying it, so every
 * token of that user is revoked and they must sign in again (reuse detection).
 */
export async function rotateRefreshToken(
  db: Db,
  token: string,
  now = Date.now(),
): Promise<RotateResult> {
  const hash = await hashRefreshToken(token);
  const [row] = await db.select().from(refreshTokens).where(eq(refreshTokens.tokenHash, hash));
  if (!row) return { ok: false, reason: "invalid" };

  if (row.revokedAt !== null) {
    await revokeAllRefreshTokens(db, row.userId, now);
    return { ok: false, reason: "reused" };
  }
  if (row.expiresAt <= now) return { ok: false, reason: "invalid" };

  // Conditional on still being unrevoked, so two concurrent uses of the same token can't
  // both succeed: the loser is treated as reuse.
  const revoked = await db
    .update(refreshTokens)
    .set({ revokedAt: now })
    .where(and(eq(refreshTokens.id, row.id), isNull(refreshTokens.revokedAt)))
    .returning({ id: refreshTokens.id });
  if (revoked.length === 0) {
    await revokeAllRefreshTokens(db, row.userId, now);
    return { ok: false, reason: "reused" };
  }

  return {
    ok: true,
    userId: row.userId,
    refreshToken: await issueRefreshToken(db, row.userId, now),
  };
}

export async function revokeAllRefreshTokens(db: Db, userId: string, now = Date.now()) {
  await db
    .update(refreshTokens)
    .set({ revokedAt: now })
    .where(and(eq(refreshTokens.userId, userId), isNull(refreshTokens.revokedAt)));
}
