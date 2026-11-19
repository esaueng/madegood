import { and, eq, gt, isNull, or } from "drizzle-orm";
import type { DrizzleD1Database } from "drizzle-orm/d1";
import { jwtVerify, SignJWT } from "jose";
import { refreshTokens } from "../db/schema";

export const ACCESS_TOKEN_TTL_S = 15 * 60;
export const REFRESH_TOKEN_TTL_MS = 60 * 24 * 60 * 60 * 1000;

const ISSUER = "madegood";
const AUDIENCE = "madegood-api";
/**
 * Website access tokens have their own audience and always name their sign-in (`sid`),
 * so a website token without one is never accepted (review of #63).
 */
const WEB_AUDIENCE = "madegood-web";
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
 * Signs a 15-minute access token. With `sessionId`, it is a website token: audience
 * `madegood-web` and a `sid` claim naming its refresh-token family, so signing out ends it
 * at once (middleware.ts). Without, it is an app token (`madegood-api`).
 */
export async function signAccessToken(
  userId: string,
  secret: string | undefined,
  sessionId?: string,
) {
  return new SignJWT(sessionId ? { sid: sessionId } : {})
    .setProtectedHeader({ alg: "HS256", typ: TYP })
    .setIssuer(ISSUER)
    .setAudience(sessionId ? WEB_AUDIENCE : AUDIENCE)
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TOKEN_TTL_S}s`)
    .sign(signingKey(secret));
}

export type AccessClaims = { userId: string; sessionId: string | null; web: boolean };

/**
 * The claims of a valid token, or null for any invalid one, including a website token
 * without `sid`. A token with `sid` is only good while that sign-in is live; callers check
 * that with isFamilyLive.
 */
export async function verifyAccessClaims(
  token: string,
  secret: string | undefined,
): Promise<AccessClaims | null> {
  const key = signingKey(secret);
  try {
    const { payload } = await jwtVerify(token, key, {
      issuer: ISSUER,
      audience: [AUDIENCE, WEB_AUDIENCE],
      algorithms: ["HS256"],
      typ: TYP,
      requiredClaims: ["sub", "exp"],
    });
    if (typeof payload.sub !== "string" || payload.sub === "") return null;
    const sid = typeof payload.sid === "string" && payload.sid !== "" ? payload.sid : null;
    const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    const web = audiences.includes(WEB_AUDIENCE);
    if (web && sid === null) return null;
    return { userId: payload.sub, sessionId: sid, web };
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
 * A rotated token presented again within this window gets back the same successor it was
 * already given, provided that successor is still unused: two browser tabs, or a retried
 * request, can send the same refresh token moments apart. There is never a second,
 * parallel chain: whoever uses the successor second trips reuse detection. Later than this,
 * or once the successor was used, a replay is reuse.
 */
export const REFRESH_REUSE_GRACE_MS = 30 * 1000;

const newToken = () => base64url(crypto.getRandomValues(new Uint8Array(32)));

/**
 * The successor of a refresh token: HMAC-SHA256 of the token under the signing secret. It
 * is derived rather than random, so a replay within the grace window can be given the same
 * successor without the server storing any token in plaintext. Without the secret, a
 * token does not reveal its successor.
 */
export async function successorOf(token: string, secret: string | undefined): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    signingKey(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`madegood refresh successor v1\u0000${token}`),
  );
  return base64url(new Uint8Array(mac));
}

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
 * website), the access token is a website token naming the family.
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
/** Rows written before migration 0004, or by an older Worker since, are their own family. */
const familyOf = (row: Pick<TokenRow, "id" | "familyId">) => row.familyId ?? row.id;
const inFamily = (familyId: string) =>
  or(
    eq(refreshTokens.familyId, familyId),
    and(isNull(refreshTokens.familyId), eq(refreshTokens.id, familyId)),
  );

/** Test hooks that run between a refresh's read and its writes, to force interleavings. */
export type RotateHooks = { afterRead?: () => Promise<void> };

/**
 * Exchanges a refresh token for its successor. Each token works once. Presenting a token
 * that was already used (or revoked) means it leaked or a client is replaying it, so every
 * token of that user is revoked and they must sign in again (reuse detection). The one
 * exception is REFRESH_REUSE_GRACE_MS: within it, the same unused successor comes back.
 * A token whose family was signed out no longer exists and is simply invalid.
 */
export async function rotateRefreshToken(
  db: Db,
  token: string,
  secret: string | undefined,
  options: { now?: number; hooks?: RotateHooks } = {},
): Promise<RotateResult> {
  const now = options.now ?? Date.now();
  const hash = await hashRefreshToken(token);
  const [row] = await db.select().from(refreshTokens).where(eq(refreshTokens.tokenHash, hash));
  if (!row) return { ok: false, reason: "invalid" };
  if (row.familyId === null) {
    // Lazily repair rows an older Worker wrote without a family.
    await db
      .update(refreshTokens)
      .set({ familyId: row.id })
      .where(and(eq(refreshTokens.id, row.id), isNull(refreshTokens.familyId)));
  }
  await options.hooks?.afterRead?.();
  const familyId = familyOf(row);
  const successor = await successorOf(token, secret);

  if (row.revokedAt === null) {
    if (row.expiresAt <= now) return { ok: false, reason: "invalid" };
    if (await consumeRefreshToken(db, row, successor, now)) {
      return { ok: true, userId: row.userId, refreshToken: successor, familyId };
    }
    // Another request changed the token after we read it: the same rules as a replay.
  }
  return replay(db, row.id, row.userId, familyId, successor, now);
}

/**
 * A token that is already rotated, revoked or gone. Within the grace window its own
 * unused successor comes back; a deleted token (signed out) is invalid; anything else is
 * reuse and revokes every token of the user.
 */
async function replay(
  db: Db,
  id: string,
  userId: string,
  familyId: string,
  successor: string,
  now: number,
): Promise<RotateResult> {
  const [current] = await db.select().from(refreshTokens).where(eq(refreshTokens.id, id));
  if (!current) return { ok: false, reason: "invalid" };
  if (
    current.revokedAt !== null &&
    now - current.revokedAt <= REFRESH_REUSE_GRACE_MS &&
    current.expiresAt > now
  ) {
    const [next] = await db
      .select()
      .from(refreshTokens)
      .where(eq(refreshTokens.tokenHash, await hashRefreshToken(successor)));
    if (next && next.revokedAt === null && next.expiresAt > now) {
      return { ok: true, userId, refreshToken: successor, familyId };
    }
  }
  // Sign-out deletes the whole family in one statement. If it ran meanwhile, this is not
  // theft: fail this refresh and leave the user's other sign-ins alone.
  const [still] = await db
    .select({ id: refreshTokens.id })
    .from(refreshTokens)
    .where(eq(refreshTokens.id, id));
  if (!still) return { ok: false, reason: "invalid" };
  await revokeAllRefreshTokens(db, userId, now);
  return { ok: false, reason: "reused" };
}

/** Whether a sign-in (refresh-token family) is still live: it has an unrevoked token. */
export async function isFamilyLive(db: Db, familyId: string, now = Date.now()) {
  const [row] = await db
    .select({ id: refreshTokens.id })
    .from(refreshTokens)
    .where(
      and(inFamily(familyId), isNull(refreshTokens.revokedAt), gt(refreshTokens.expiresAt, now)),
    )
    .limit(1);
  return row !== undefined;
}

/**
 * Signs out the sign-in that `token` belongs to: deletes every token of its family in one
 * statement, including a successor a concurrent refresh just issued. Deleted (rather than
 * revoked) so a late refresh with one of them is plainly invalid, not reuse that would
 * sign out the user's other devices.
 */
export async function endRefreshFamily(db: Db, token: string) {
  const hash = await hashRefreshToken(token);
  const [row] = await db
    .select({ id: refreshTokens.id, familyId: refreshTokens.familyId })
    .from(refreshTokens)
    .where(eq(refreshTokens.tokenHash, hash));
  if (!row) return;
  await db.delete(refreshTokens).where(inFamily(familyOf(row)));
}

/**
 * Revokes `row` and stores `successor` in one D1 batch (a single transaction), and only
 * if `row` was still unrevoked at that moment. Returns whether it did.
 *
 * Two separate writes are not enough (review of #36): request A revokes the token, request
 * B with the same token sees reuse and revokes every token of the user, and then A inserts
 * an unrevoked successor, so a stolen token would survive reuse detection. Inside the batch
 * nothing can run between the two statements, and the insert happens only when the update
 * changed a row. Exported for the tests that force interleavings.
 */
export async function consumeRefreshToken(
  db: Db,
  row: { id: string; userId: string; familyId?: string | null },
  successor: string,
  now = Date.now(),
): Promise<boolean> {
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
        await hashRefreshToken(successor),
        now + REFRESH_TOKEN_TTL_MS,
        now,
        row.familyId ?? row.id,
      ),
  ]);
  return revoked?.meta.changes === 1;
}

export async function revokeAllRefreshTokens(db: Db, userId: string, now = Date.now()) {
  await db
    .update(refreshTokens)
    .set({ revokedAt: now })
    .where(and(eq(refreshTokens.userId, userId), isNull(refreshTokens.revokedAt)));
}
