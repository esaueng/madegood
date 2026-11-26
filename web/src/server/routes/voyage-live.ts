import { createRoute, z } from "@hono/zod-openapi";
import type { Context, TypedResponse } from "hono";
import { bodyLimit } from "hono/body-limit";
import { type AuthEnv, requireAuth } from "../auth/middleware";
import { apiError, errorResponse } from "../lib/errors";
import { createRouter } from "../lib/router";
import { sharingAvailable } from "../lib/sharing-available";
import { hashSlug, shareCodePattern, unavailable } from "../lib/voyage-sharing";
import { liveVoyage, locateShare } from "../live/registry";
import { viewerPage } from "../live/viewer-page";
import { deviceId } from "./voyages";

const path = "/voyages/{voyageId}";
const params = z.object({ voyageId: deviceId });
const envelope = <S extends z.ZodType>(schema: S) => ({ "application/json": { schema } });
const common = {
  tags: ["voyage live"],
  security: [{ bearerAuth: [] }],
};
const errors = {
  400: errorResponse("The request is invalid."),
  401: errorResponse("A current owner account is required."),
  404: errorResponse("The live voyage is unavailable."),
};
const conflict = errorResponse(
  "The sample ID or share state conflicts, the grant is stale, or the voyage is at capacity.",
);
const conflictOrSharingDisabled = errorResponse(
  "The share state conflicts, the grant is stale, or the voyage is at capacity; or the " +
    "command would issue or reopen a link while the account's sharing is off " +
    "(`sharing_disabled`).",
);
const payloadTooLarge = errorResponse("The request body exceeds 64 KiB.");

const Fix = z.object({
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  capturedAtMs: z.int().min(0).max(8_640_000_000_000_000),
});
const Viewer = z
  .discriminatedUnion("status", [
    z.object({ status: z.literal("unavailable") }),
    z.object({ status: z.literal("available"), current: Fix, segments: z.array(z.array(Fix)) }),
  ])
  .openapi("VoyageViewerState");

const ownerFields = {
  sharing: z.enum(["off", "on", "paused"]),
  delayS: z.int().nonnegative(),
  grantGeneration: z.int().positive().optional().openapi({
    description: "Current valid grant, including when paused. Omitted when sharing is off.",
  }),
  preview: Viewer,
};
const Owner = z.object(ownerFields).openapi("VoyageOwnerSharingState");
const ChangeShareResult = z
  .object({
    ...ownerFields,
    slug: z
      .string()
      .optional()
      .openapi({ description: "Returned only when a new link is issued." }),
  })
  .openapi("VoyageChangeShareResult");

const Position = z.strictObject({
  ...Fix.shape,
  sampleId: deviceId,
  segmentId: deviceId.openapi({
    description: "Stable segment UUID. Start a new one at every recording break or leg boundary.",
  }),
});
const Positions = z
  .strictObject({
    grantGeneration: z
      .int()
      .positive()
      .openapi({ description: "The owner grant under which these positions were queued." }),
    positions: z.array(Position).min(1).max(250),
  })
  .openapi("VoyagePositionBatch");
const Receipts = z
  .object({
    receipts: z.array(z.object({ sampleId: deviceId, receivedAtMs: z.int().nonnegative() })),
  })
  .openapi("VoyagePositionReceipts");
const delayS = z.int().min(0).max(86_400);
const grantFields = {
  delayS,
  expiresInS: z
    .int()
    .min(1)
    .max(7 * 86_400),
};
const Command = z
  .discriminatedUnion("action", [
    z.strictObject({ action: z.literal("issue"), ...grantFields }),
    z.strictObject({ action: z.literal("rotate"), ...grantFields }),
    z.strictObject({ action: z.literal("pause") }),
    z.strictObject({ action: z.literal("resume") }),
    z.strictObject({ action: z.literal("revoke") }),
    z.strictObject({ action: z.literal("delay"), delayS }),
  ])
  .openapi("VoyageShareCommand");

const postPositions = createRoute({
  ...common,
  method: "post",
  path: `${path}/positions`,
  operationId: "postVoyagePositions",
  summary: "Accept a batch of active voyage fixes",
  request: { params, body: { required: true, content: envelope(Positions) } },
  responses: {
    200: {
      description: "Original server receipt per distinct sample ID.",
      content: envelope(Receipts),
    },
    ...errors,
    409: conflict,
    413: payloadTooLarge,
  },
});
const getShare = createRoute({
  ...common,
  method: "get",
  path: `${path}/sharing`,
  operationId: "getVoyageSharing",
  summary: "Read the owner's live sharing controls and preview",
  request: { params },
  responses: { 200: { description: "Owner view.", content: envelope(Owner) }, ...errors },
});
const changeShare = createRoute({
  ...common,
  method: "post",
  path: `${path}/sharing`,
  operationId: "changeVoyageSharing",
  summary: "Issue a new live grant or change the current grant",
  request: { params, body: { required: true, content: envelope(Command) } },
  responses: {
    200: {
      description: "Owner view and any new link credential.",
      content: envelope(ChangeShareResult),
    },
    ...errors,
    409: conflictOrSharingDisabled,
    413: payloadTooLarge,
  },
});
const readViewer = createRoute({
  method: "get",
  path: "/live/{slug}",
  tags: ["voyage live"],
  operationId: "getVoyageLive",
  summary: "Read a share projection or upgrade to a WebSocket",
  request: { params: z.object({ slug: z.string() }) },
  responses: {
    101: {
      description: "WebSocket. Every message replaces the entire view with a VoyageViewerState.",
    },
    200: {
      description: "Full projection or uniform unavailable state.",
      content: envelope(Viewer),
    },
    404: errors[404],
  },
});

const error = (
  c: Context,
  status:
    | "unauthorized"
    | "not_found"
    | "sync_conflict"
    | "live_capacity"
    | "stale_grant"
    | "sharing_disabled",
) => {
  switch (status) {
    case "unauthorized":
      return apiError(c, 401, status);
    case "not_found":
      return apiError(c, 404, status);
    default:
      return apiError(c, 409, status);
  }
};
const limit = bodyLimit({
  maxSize: 64 * 1024,
  onError: (c) => apiError(c, 413, "payload_too_large"),
});
export const voyageLiveRoutes = createRouter<AuthEnv>();
voyageLiveRoutes.use("/voyages/:voyageId/positions", noStoreAndEnabled, requireAuth, limit);
voyageLiveRoutes.use("/voyages/:voyageId/sharing", noStoreAndEnabled, requireAuth, limit);
voyageLiveRoutes.use("/live/:slug", noStoreAndEnabled);

async function noStoreAndEnabled(c: Context, next: () => Promise<void>) {
  c.header("Cache-Control", "private, no-store");
  c.header("Referrer-Policy", "no-referrer");
  if (c.env.VOYAGE_LIVE_LOCAL !== "1" || !c.env.VOYAGE_LIVE || !sharingAvailable(c.env)) {
    return apiError(c, 404, "not_found");
  }
  await next();
}

voyageLiveRoutes.openapi(postPositions, async (c) => {
  const key = { userId: c.var.userId, ...c.req.valid("param") };
  const { grantGeneration, positions } = c.req.valid("json");
  const result = await liveVoyage(c.env, key).ingest(key, grantGeneration, positions);
  return result.status === "ok"
    ? c.json({ receipts: result.receipts }, 200)
    : error(c, result.status);
});
voyageLiveRoutes.openapi(getShare, async (c) => {
  const key = { userId: c.var.userId, ...c.req.valid("param") };
  const result = await liveVoyage(c.env, key).owner(key);
  return result.status === "ok"
    ? (result.response as Response & TypedResponse<z.infer<typeof Owner>, 200, "json">)
    : apiError(c, result.status === "unauthorized" ? 401 : 404, result.status);
});
voyageLiveRoutes.openapi(changeShare, async (c) => {
  const key = { userId: c.var.userId, ...c.req.valid("param") };
  // The object refuses to issue or reopen a link while the account's sharing is off.
  const result = await liveVoyage(c.env, key).configure(key, c.req.valid("json"));
  if (result.status !== "ok") return error(c, result.status);
  return result.response as Response &
    TypedResponse<z.infer<typeof ChangeShareResult>, 200, "json">;
});

voyageLiveRoutes.openapi(readViewer, async (c) => {
  const { slug } = c.req.valid("param");
  if (!shareCodePattern.test(slug)) return c.json(unavailable, 200);
  const hash = await hashSlug(slug);
  try {
    const key = await locateShare(c.env.DB, hash);
    if (key) {
      const upgrade = c.req.header("Upgrade")?.toLowerCase() === "websocket";
      return await liveVoyage(c.env, key).fetch(`https://voyage.internal/${hash}`, {
        headers: upgrade ? { Upgrade: "websocket" } : {},
      });
    }
  } catch {
    // Lookup or object failure yields the same payload as an unavailable link.
  }
  return c.json(unavailable, 200);
});

export const voyageViewerPage = createRouter<{ Bindings: Env }>();
voyageViewerPage.use("/v/:slug", noStoreAndEnabled);
voyageViewerPage.get("/v/:slug", (c) => viewerPage(c));
