import { and, eq, gt, isNull } from "drizzle-orm";
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

/**
 * Signs a 15-minute access token. `sessionId` (the `sid` claim) binds a website token to
 * its refresh-token family, so signing out on the web ends it at once (middleware.ts).
 */
export async function signAccessToken(
  userId: string,
  secret: string | undefined,
  sessionId?: string,
) {
  return new SignJWT(sessionId ? { sid: sessionId } : {})
    .setProtectedHeader({ alg: "HS256", typ: TYP })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TOKEN_TTL_S}s`)
    .sign(signingKey(secret));
}

/** The user ID and session family of a valid token, or null for any invalid one. */
export async function verifyAccessClaims(
  token: string,
  secret: string | undefined,
): Promise<{ userId: string; sessionId: string | null } | null> {
  const key = signingKey(secret);
  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: ISSUER,
      audience: AUDIENCE,
      algorithms: ["HS256"],
      typ: TYP,
      requiredClaims: ["sub", "exp"],
    });
    if (typeof payload.sub !== "string" || payload.sub === "") return null;
    const sid = payload.sid;
    return { userId: payload.sub, sessionId: typeof sid === "string" && sid !== "" ? sid : null };
  } catch {
    return null;
  }
}

/** Returns the user ID, or null for any invalid, expired or foreign token. */
export async function verifyAccessToken(
  token: string,
  secret: string | undefined,
): Promise<string | null> {
  return (await verifyAccessClaims(token, secret))?.userId ?? null;
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

type Db = DrizzleD1Database<Record<string, unknown>> & { $client: D1Database };

/**
 * A rotated token presented again within this window gets another successor in its family
 * instead of tripping reuse detection: two browser tabs, or a retried request, can send
 * the same refresh token moments apart. Later than this, reuse still revokes everything.
 */
export const REFRESH_REUSE_GRACE_MS = 30 * 1000;

const newToken = () => base64url(crypto.getRandomValues(new Uint8Array(32)));

/**
 * Creates a random 256-bit refresh token that starts a new family (a sign-in); only its
 * SHA-256 hash is stored. The family ID is the first token's ID.
 */
export async function issueRefreshToken(db: Db, userId: string, now = Date.now()) {
  const token = newToken();
  const id = crypto.randomUUID();
  await db.insert(refreshTokens).values({
    id,
    userId,
    familyId: id,
    tokenHash: await hashRefreshToken(token),
    expiresAt: now + REFRESH_TOKEN_TTL_MS,
    createdAt: now,
  });
  return { token, familyId: id };
}

/**
 * Signs in: a new refresh-token family and an access token. With `bindSession` (the
 * website), the access token names the family, so ending the family ends it too.
 */
export async function issueTokenPair(
  db: Db,
  userId: string,
  secret: string | undefined,
  options: { bindSession?: boolean } = {},
) {
  const { token: refreshToken, familyId } = await issueRefreshToken(db, userId);
  const accessToken = await signAccessToken(
    userId,
    secret,
    options.bindSession ? familyId : undefined,
  );
  return { accessToken, refreshToken };
}

export type RotateResult =
  | { ok: true; userId: string; refreshToken: string; familyId: string }
  | { ok: false; reason: "invalid" | "reused" };

type TokenRow = typeof refreshTokens.$inferSelect;
const familyOf = (row: Pick<TokenRow, "id" | "familyId">) => row.familyId ?? row.id;

/**
 * Exchanges a refresh token for a new one. Each token works once. Presenting a token that
 * was already used (or revoked) means it leaked or a client is replaying it, so every
 * token of that user is revoked and they must sign in again (reuse detection), except
 * within REFRESH_REUSE_GRACE_MS of its rotation while its family is still live. A token
 * whose family was signed out no longer exists and is simply invalid.
 */
export async function rotateRefreshToken(
  db: Db,
  token: string,
  now = Date.now(),
): Promise<RotateResult> {
  const hash = await hashRefreshToken(token);
  const [row] = await db.select().from(refreshTokens).where(eq(refreshTokens.tokenHash, hash));
  if (!row) return { ok: false, reason: "invalid" };
  const familyId = familyOf(row);

  if (row.revokedAt !== null) {
    if (now - row.revokedAt <= REFRESH_REUSE_GRACE_MS && row.expiresAt > now) {
      const successor = await issueInLiveFamily(db, row.userId, familyId, now);
      if (successor !== null) {
        return { ok: true, userId: row.userId, refreshToken: successor, familyId };
      }
    }
    await revokeAllRefreshTokens(db, row.userId, now);
    return { ok: false, reason: "reused" };
  }
  if (row.expiresAt <= now) return { ok: false, reason: "invalid" };

  const successor = await consumeRefreshToken(db, row, now);
  if (successor === null) {
    // Something else changed this token after we read it. If its family was signed out
    // the row is gone: that is not theft, so the user's other devices stay signed in.
    const [still] = await db
      .select({ id: refreshTokens.id })
      .from(refreshTokens)
      .where(eq(refreshTokens.id, row.id));
    if (!still) return { ok: false, reason: "invalid" };
    // Otherwise another request used or revoked it: treat it as reuse.
    await revokeAllRefreshTokens(db, row.userId, now);
    return { ok: false, reason: "reused" };
  }
  return { ok: true, userId: row.userId, refreshToken: successor, familyId };
}

/**
 * Adds a token to `familyId` only while the family still has a live token, in one
 * statement, so a family that was signed out or revoked for reuse gets nothing.
 */
async function issueInLiveFamily(
  db: Db,
  userId: string,
  familyId: string,
  now: number,
): Promise<string | null> {
  const token = newToken();
  const result = await db.$client
    .prepare(
      `INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, created_at, family_id)
       SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (
         SELECT 1 FROM refresh_tokens
         WHERE family_id = ? AND revoked_at IS NULL AND expires_at > ?
       )`,
    )
    .bind(
      crypto.randomUUID(),
      userId,
      await hashRefreshToken(token),
      now + REFRESH_TOKEN_TTL_MS,
      now,
      familyId,
      familyId,
      now,
    )
    .run();
  return result.meta.changes === 1 ? token : null;
}

/** Whether a sign-in (refresh-token family) is still live: it has an unrevoked token. */
export async function isFamilyLive(db: Db, familyId: string, now = Date.now()) {
  const [row] = await db
    .select({ id: refreshTokens.id })
    .from(refreshTokens)
    .where(
      and(
        eq(refreshTokens.familyId, familyId),
        isNull(refreshTokens.revokedAt),
        gt(refreshTokens.expiresAt, now),
      ),
    )
    .limit(1);
  return row !== undefined;
}

/**
 * Signs out the sign-in that `token` belongs to: deletes every token of its family,
 * including any successor a concurrent refresh just issued. Deleted (rather than revoked)
 * so a late refresh with one of them is plainly invalid, not reuse that would sign out
 * the user's other devices.
 */
export async function endRefreshFamily(db: Db, token: string) {
  const hash = await hashRefreshToken(token);
  const [row] = await db
    .select({ id: refreshTokens.id, familyId: refreshTokens.familyId })
    .from(refreshTokens)
    .where(eq(refreshTokens.tokenHash, hash));
  if (!row) return;
  await db.delete(refreshTokens).where(eq(refreshTokens.familyId, familyOf(row)));
}

/**
 * Revokes `row` and issues its successor in one D1 batch (a single transaction), and only
 * if `row` was still unrevoked at that moment. Returns the new token, or null when it was
 * already used or revoked.
 *
 * Two separate writes are not enough (review of #36): request A revokes the token, request
 * B with the same token sees reuse and revokes every token of the user, and then A inserts
 * an unrevoked successor, so a stolen token would survive reuse detection. Inside the batch
 * nothing can run between the two statements, and the insert happens only when the update
 * changed a row. Exported for the test that forces that interleaving.
 */
export async function consumeRefreshToken(
  db: Db,
  row: { id: string; userId: string; familyId?: string | null },
  now = Date.now(),
): Promise<string | null> {
  const token = newToken();
  const tokenHash = await hashRefreshToken(token);
  // Plain D1 statements: Drizzle's batch has no raw INSERT ... SELECT, and the two must
  // share one batch. changes() is the row count of the update just before it.
  const d1 = db.$client;
  const [revoked] = await d1.batch([
    d1
      .prepare("UPDATE refresh_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
      .bind(now, row.id),
    d1
      .prepare(
        `INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, created_at, family_id)
         SELECT ?, ?, ?, ?, ?, ? WHERE changes() = 1`,
      )
      .bind(
        crypto.randomUUID(),
        row.userId,
        tokenHash,
        now + REFRESH_TOKEN_TTL_MS,
        now,
        row.familyId ?? row.id,
      ),
  ]);
  return revoked?.meta.changes === 1 ? token : null;
}

export async function revokeAllRefreshTokens(db: Db, userId: string, now = Date.now()) {
  await db
    .update(refreshTokens)
    .set({ revokedAt: now })
    .where(and(eq(refreshTokens.userId, userId), isNull(refreshTokens.revokedAt)));
}
