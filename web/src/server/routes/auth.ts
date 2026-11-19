import { createRoute, z } from "@hono/zod-openapi";
import { drizzle } from "drizzle-orm/d1";
import type { AppEnv } from "../app";
import { InvalidIdentityToken, parseAudiences, verifyAppleIdentityToken } from "../auth/apple";
import { issueTokenPair, rotateRefreshToken, signAccessToken } from "../auth/tokens";
import { AccountDeleting, cleanDisplayName, toUserBody, UserBody } from "../auth/users";
import type { User } from "../db/schema";
import { signInAppleSubject } from "../lib/account-deletion";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";

const TokenPair = z.object({
  accessToken: z
    .string()
    .openapi({ description: "Bearer token for the API; expires in 15 minutes." }),
  refreshToken: z.string().openapi({
    description: "Single-use token for POST /auth/refresh; expires in 60 days.",
  }),
});

const SignInResponse = TokenPair.extend({ user: UserBody }).openapi("SignInResponse");

const appleRoute = createRoute({
  method: "post",
  path: "/auth/apple",
  summary: "Sign in with Apple",
  description:
    "Exchanges a Sign in with Apple identity token for API tokens, creating the account on first sign-in.",
  tags: ["auth"],
  request: {
    body: {
      required: true,
      content: {
        "application/json": {
          schema: z
            .object({
              identityToken: z.string().min(1).max(8192),
              displayName: z
                .string()
                .max(200)
                .optional()
                .openapi({ description: "The name Apple shares on the first authorization." }),
            })
            .openapi("AppleSignInRequest"),
        },
      },
    },
  },
  responses: {
    200: {
      description: "Signed in.",
      content: { "application/json": { schema: SignInResponse } },
    },
    400: errorResponse("The request body is invalid."),
    401: errorResponse("The identity token is invalid, expired or for another app."),
    409: errorResponse("The account is being deleted (`account_deleting`)."),
  },
});

const refreshRoute = createRoute({
  method: "post",
  path: "/auth/refresh",
  summary: "Rotate a refresh token",
  description:
    "Exchanges a refresh token for a new access and refresh token. Each refresh token works once; " +
    "reusing one signs the user out everywhere.",
  tags: ["auth"],
  request: {
    body: {
      required: true,
      content: {
        "application/json": {
          schema: z.object({ refreshToken: z.string().min(1).max(512) }).openapi("RefreshRequest"),
        },
      },
    },
  },
  responses: {
    200: {
      description: "A new token pair.",
      content: { "application/json": { schema: TokenPair.openapi("TokenPair") } },
    },
    400: errorResponse("The request body is invalid."),
    401: errorResponse("The refresh token is invalid, expired, or was already used."),
  },
});

export const auth = createRouter<AppEnv>()
  .openapi(appleRoute, async (c) => {
    const { identityToken, displayName } = c.req.valid("json");
    let sub: string;
    try {
      ({ sub } = await verifyAppleIdentityToken(
        identityToken,
        parseAudiences(c.env.APPLE_AUDIENCES),
      ));
    } catch (err) {
      if (err instanceof InvalidIdentityToken) {
        return apiError(c, 401, "invalid_identity_token", "The Apple identity token is not valid.");
      }
      throw err;
    }
    const db = drizzle(c.env.DB);
    let signedIn: { user: User; tokens: Awaited<ReturnType<typeof issueTokenPair>> };
    try {
      signedIn = await signInAppleSubject(c.env, sub, cleanDisplayName(displayName), (user) =>
        issueTokenPair(db, user.id, c.env.JWT_SIGNING_KEY),
      );
    } catch (err) {
      if (err instanceof AccountDeleting) {
        return apiError(
          c,
          409,
          "account_deleting",
          "This account is being deleted. Try again in an hour to start a new one.",
        );
      }
      throw err;
    }
    const { user, tokens } = signedIn;
    return c.json({ ...tokens, user: toUserBody(user) }, 200);
  })
  .openapi(refreshRoute, async (c) => {
    const db = drizzle(c.env.DB);
    const result = await rotateRefreshToken(
      db,
      c.req.valid("json").refreshToken,
      c.env.JWT_SIGNING_KEY,
      { client: "app" },
    );
    if (!result.ok) {
      return result.reason === "reused"
        ? apiError(c, 401, "refresh_token_reused", "This refresh token was already used.")
        : apiError(c, 401, "invalid_refresh_token", "The refresh token is not valid.");
    }
    const accessToken = await signAccessToken(result.userId, c.env.JWT_SIGNING_KEY);
    return c.json({ accessToken, refreshToken: result.refreshToken }, 200);
  });
