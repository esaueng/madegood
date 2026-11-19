import { createRoute, z } from "@hono/zod-openapi";
import { and, eq } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { type ExportJob, exportJobs } from "../db/schema";
import { apiError, errorResponse } from "../lib/errors";
import {
  type CommittedPart,
  createExportJob,
  EXPORT_TTL_MS,
  EXPORTS_PER_DAY,
  firstMessage,
  recentExports,
  sendExportStep,
} from "../lib/export-job";
import { createRouter } from "../lib/router";

// Account export as a background job (lib/export-job.ts): start one, watch its progress,
// download its ZIP parts while they last.

const security = [{ bearerAuth: [] }];

const ExportBody = z
  .object({
    id: z.string(),
    status: z.enum(["queued", "building", "ready", "failed", "expired"]),
    createdAt: z.string(),
    expiresAt: z.string().nullable().openapi({ description: "When the parts are deleted." }),
    progress: z.object({
      done: z.number().int(),
      total: z.number().int().openapi({ description: "Documents and track files to write." }),
    }),
    parts: z
      .array(
        z.object({
          part: z.number().int(),
          bytes: z.number().int(),
          url: z.string().openapi({ description: "Path of the ZIP under the API root." }),
        }),
      )
      .openapi({
        description: "Set once `ready`. Part 1 holds manifest.json, which lists every part.",
      }),
    omitted: z.number().int().openapi({
      description:
        "Set once `ready`: files left out of the export, each listed in errors.json in part 1.",
    }),
    error: z.string().nullable(),
  })
  .openapi("AccountExport");

function toBody(job: ExportJob): z.infer<typeof ExportBody> {
  const committed = job.status === "ready" ? (JSON.parse(job.partsJson) as CommittedPart[]) : [];
  const parts = committed
    .sort((a, b) => a.part - b.part)
    .map((p) => ({ part: p.part, bytes: p.bytes, url: `/me/exports/${job.id}/parts/${p.part}` }));
  return {
    id: job.id,
    status: job.status,
    createdAt: new Date(job.createdAt).toISOString(),
    expiresAt: job.expiresAt === null ? null : new Date(job.expiresAt).toISOString(),
    progress: { done: Math.min(job.cursor, job.totalItems), total: job.totalItems },
    parts,
    omitted: committed.find((p) => p.part === 1)?.omitted ?? 0,
    error: job.error,
  };
}

const ExportParams = z.object({ id: z.string().uuid() });

const createRouteDef = createRoute({
  method: "post",
  path: "/me/exports",
  operationId: "createAccountExport",
  summary: "Start exporting all of the signed-in user's data",
  description:
    "Freezes the list of the account's sessions and voyages and builds ZIP parts in the " +
    `background; poll GET /me/exports/{id}. One export at a time, at most ${EXPORTS_PER_DAY} ` +
    `a day. Parts are kept for ${EXPORT_TTL_MS / (24 * 3600 * 1000)} days.`,
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  responses: {
    202: { description: "Started.", content: { "application/json": { schema: ExportBody } } },
    401: errorResponse("Missing or invalid access token."),
    409: errorResponse(
      "An export is already running (`export_in_progress`); its ID is in `message`.",
    ),
    413: errorResponse("The account holds too many sessions to export (`export_too_large`)."),
    429: errorResponse(`More than ${EXPORTS_PER_DAY} exports in a day (\`rate_limited\`).`),
  },
});

const listRoute = createRoute({
  method: "get",
  path: "/me/exports",
  operationId: "listAccountExports",
  summary: "The signed-in user's recent exports, newest first",
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  responses: {
    200: {
      description: "Up to five exports.",
      content: {
        "application/json": { schema: z.object({ exports: z.array(ExportBody) }) },
      },
    },
    401: errorResponse("Missing or invalid access token."),
  },
});

const getRouteDef = createRoute({
  method: "get",
  path: "/me/exports/{id}",
  operationId: "getAccountExport",
  summary: "An export's status, progress and parts",
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  request: { params: ExportParams },
  responses: {
    200: { description: "The export.", content: { "application/json": { schema: ExportBody } } },
    400: errorResponse("The ID is not a UUID."),
    401: errorResponse("Missing or invalid access token."),
    404: errorResponse("No such export for this user."),
  },
});

const partRoute = createRoute({
  method: "get",
  path: "/me/exports/{id}/parts/{part}",
  operationId: "getAccountExportPart",
  summary: "Download one ZIP part of a finished export",
  tags: ["account"],
  security,
  middleware: [requireAuth] as const,
  request: {
    params: ExportParams.extend({ part: z.coerce.number().int().min(1).max(10_000) }),
  },
  responses: {
    200: {
      description: "The ZIP part.",
      content: { "application/zip": { schema: z.string().openapi({ format: "binary" }) } },
    },
    400: errorResponse("The parameters are invalid."),
    401: errorResponse("Missing or invalid access token."),
    404: errorResponse("No such export or part for this user, or it has expired."),
    409: errorResponse("The export is not finished (`export_not_ready`)."),
  },
});

export const exportRoutes = createRouter<AuthEnv>();
exportRoutes.use("/me/exports", async (c, next) => {
  await next();
  c.header("Cache-Control", "private, no-store");
});
exportRoutes.use("/me/exports/*", async (c, next) => {
  await next();
  c.header("Cache-Control", "private, no-store");
});

exportRoutes.openapi(createRouteDef, async (c) => {
  const result = await createExportJob(c.env, c.var.userId);
  if (result.kind === "in_progress") {
    return apiError(c, 409, "export_in_progress", result.job.id);
  }
  if (result.kind === "rate_limited") {
    return apiError(c, 429, "rate_limited", "You can start another export tomorrow.");
  }
  if (result.kind === "account_gone") {
    return apiError(c, 401, "unauthorized", "The account no longer exists.");
  }
  if (result.kind === "too_large") {
    return apiError(c, 413, "export_too_large", "This account holds too many sessions to export.");
  }
  let ctx: ExecutionContext | null = null;
  try {
    ctx = c.executionCtx as ExecutionContext;
  } catch {}
  try {
    await sendExportStep(c.env, ctx, firstMessage(result.job));
  } catch (error) {
    // The job stays queued; the scheduled sweep resumes it.
    console.error("Could not queue the export.", error);
  }
  return c.json(toBody(result.job), 202);
});

exportRoutes.openapi(listRoute, async (c) => {
  const jobs = await recentExports(drizzle(c.env.DB), c.var.userId);
  return c.json({ exports: jobs.map(toBody) }, 200);
});

const findJob = async (db: ReturnType<typeof drizzle>, userId: string, id: string) =>
  (
    await db
      .select()
      .from(exportJobs)
      .where(and(eq(exportJobs.id, id), eq(exportJobs.userId, userId)))
  )[0];

exportRoutes.openapi(getRouteDef, async (c) => {
  const job = await findJob(drizzle(c.env.DB), c.var.userId, c.req.valid("param").id);
  return job ? c.json(toBody(job), 200) : apiError(c, 404, "not_found");
});

exportRoutes.openapi(partRoute, async (c) => {
  const { id, part } = c.req.valid("param");
  const job = await findJob(drizzle(c.env.DB), c.var.userId, id);
  if (!job) return apiError(c, 404, "not_found");
  if (job.status === "queued" || job.status === "building") {
    return apiError(c, 409, "export_not_ready", "The export is still being prepared.");
  }
  // Only a committed part, by the key its commit recorded (lib/export-job.ts).
  const committed = (JSON.parse(job.partsJson) as CommittedPart[]).find((p) => p.part === part);
  if (job.status !== "ready" || !committed || (job.expiresAt ?? 0) <= Date.now()) {
    return apiError(c, 404, "not_found", "This export has expired or has no such part.");
  }
  const object = await c.env.TRACKS.get(committed.key);
  if (!object) return apiError(c, 404, "not_found");
  const day = new Date(job.createdAt).toISOString().slice(0, 10);
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/zip",
      "Content-Length": String(object.size),
      "Content-Disposition": `attachment; filename="madegood-export-${day}-part-${part}.zip"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
});
