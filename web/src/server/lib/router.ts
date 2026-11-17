import { OpenAPIHono } from "@hono/zod-openapi";
import type { Env as HonoEnv } from "hono";
import { apiError } from "./errors";

/** An OpenAPIHono whose request validation failures use the API's error format. */
export function createRouter<E extends HonoEnv>() {
  return new OpenAPIHono<E>({
    defaultHook: (result, c) => {
      if (!result.success) {
        const message = result.error.issues
          .map((issue) => (issue.path.length ? `${issue.path.join(".")}: ` : "") + issue.message)
          .join("; ");
        return apiError(c, 400, "invalid_request", message);
      }
    },
  });
}
