import { and, eq, isNull, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { Hono } from "hono";
import type { AppEnv } from "../app";
import { HANDLE_PATTERN } from "../auth/users";
import { sessions, users } from "../db/schema";
import { ogImage, ogInfo } from "../lib/og-image";
import {
  BRAND_CARD_ALT,
  CARD_HEIGHT,
  CARD_WIDTH,
  formatDuration,
  SPORT_NAMES,
  UNITS,
} from "../og/card";

// /s/:id is the SPA's session page. The Worker serves it (wrangler.jsonc
// `run_worker_first`) to put Open Graph tags into the HTML, so shared links preview with
// the session's title, headline stats and route image. Only public and unlisted sessions
// get them; a private, deleted or unknown session gets the same generic tags and the brand
// image, so the preview never tells whether it exists. Text tags never contain positions,
// bounds or times of day; the image (lib/og-image.ts) draws only what the shared track
// shows anyone.
//
// /u/:handle, the public profile, works the same way: tags only while the profile is
// visible to everyone (routes/users.ts: at least one public session), generic otherwise.
// Profiles use the brand image.

type Image = { path: string; alt: string };
/** `pageTitle` is the document title; without it, `title · MadeGood`. */
type Preview = {
  title: string;
  description: string;
  indexable: boolean;
  image: Image;
  pageTitle?: string;
};

const SITE = "MadeGood";
const SITE_DESCRIPTION = "Open-source tracking for sailing, paddling, and time on the water.";
/** The brand card in web/public, drawn by scripts/render-og.mjs. */
export const BRAND_IMAGE: Image = { path: "/og-default.png", alt: BRAND_CARD_ALT };
const GENERIC: Preview = {
  title: "A session on MadeGood",
  pageTitle: "A session on MadeGood",
  description: SITE_DESCRIPTION,
  indexable: false,
  image: BRAND_IMAGE,
};
const GENERIC_PROFILE: Preview = {
  title: "A profile on MadeGood",
  pageTitle: "A profile on MadeGood",
  description: SITE_DESCRIPTION,
  indexable: false,
  image: BRAND_IMAGE,
};

const distance = (m: number, units: keyof typeof UNITS) =>
  `${(m * UNITS[units].distance).toFixed(2)} ${UNITS[units].distanceUnit}`;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The preview for a session ID; GENERIC unless the session is public or unlisted. */
export async function sessionPreview(db: D1Database, id: string): Promise<Preview> {
  if (!UUID.test(id)) return GENERIC;
  const [row] = await drizzle(db)
    .select({ session: sessions, units: users.units, zonesVersion: users.zonesVersion })
    .from(sessions)
    .innerJoin(users, and(eq(users.id, sessions.userId), isNull(users.deletedAt)))
    .where(and(eq(sessions.id, id.toLowerCase()), isNull(sessions.deletedAt)));
  if (!row || row.session.visibility === "private") return GENERIC;

  const session = row.session;
  const units = UNITS[row.units];
  const sport = SPORT_NAMES[session.sport];
  const parts: string[] = [sport];
  if (session.distanceM != null) {
    parts.push(distance(session.distanceM, row.units));
  }
  if (session.durationS != null) parts.push(formatDuration(session.durationS));
  if (session.maxSpeedMps != null) {
    parts.push(`max ${(session.maxSpeedMps * units.speed).toFixed(1)} ${units.speedUnit}`);
  }
  const og = await ogInfo(session, row.units, row.zonesVersion);
  return {
    title: session.title ?? sport,
    description: parts.join(" · "),
    indexable: session.visibility === "public",
    image: og ? { path: `/s/${session.id}/og.png?v=${og.fingerprint}`, alt: og.alt } : BRAND_IMAGE,
  };
}

/** The preview for a profile; GENERIC_PROFILE unless the user has a public session. */
export async function profilePreview(db: D1Database, rawHandle: string): Promise<Preview> {
  const handle = rawHandle.toLowerCase();
  if (!HANDLE_PATTERN.test(handle)) return GENERIC_PROFILE;
  const [row] = await drizzle(db)
    .select({
      handle: users.handle,
      displayName: users.displayName,
      units: users.units,
      count: sql<number>`count(${sessions.id})`,
      distanceM: sql<number>`coalesce(sum(${sessions.distanceM}), 0)`,
    })
    .from(users)
    .innerJoin(
      sessions,
      and(
        eq(sessions.userId, users.id),
        eq(sessions.visibility, "public"),
        isNull(sessions.deletedAt),
      ),
    )
    .where(and(eq(users.handle, handle), isNull(users.deletedAt)))
    .groupBy(users.id);
  if (!row || row.count === 0) return GENERIC_PROFILE;
  const sessionCount = `${row.count} public ${row.count === 1 ? "session" : "sessions"}`;
  const parts = [sessionCount];
  if (row.distanceM > 0) parts.push(distance(row.distanceM, row.units));
  return {
    title: row.displayName ? `${row.displayName} (@${row.handle})` : `@${row.handle}`,
    description: `${parts.join(" · ")} on MadeGood`,
    indexable: true,
    image: BRAND_IMAGE,
  };
}

const escapeHtml = (text: string) =>
  text.replace(
    /[&<>"']/g,
    (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch] ?? ch,
  );

/** The SPA shell with the preview's title, description and Open Graph tags. */
export function injectPreview(shell: Response, preview: Preview, url: string): Response {
  const image = new URL(preview.image.path, url).toString();
  const title = preview.pageTitle ?? `${preview.title} · ${SITE}`;
  const meta = [
    ["property", "og:site_name", SITE],
    ["property", "og:type", "website"],
    ["property", "og:title", preview.title],
    ["property", "og:description", preview.description],
    ["property", "og:url", url],
    ["property", "og:image", image],
    ["property", "og:image:type", "image/png"],
    ["property", "og:image:width", String(CARD_WIDTH)],
    ["property", "og:image:height", String(CARD_HEIGHT)],
    ["property", "og:image:alt", preview.image.alt],
    ["name", "twitter:card", "summary_large_image"],
    ["name", "twitter:title", preview.title],
    ["name", "twitter:description", preview.description],
    ["name", "twitter:image", image],
    ["name", "twitter:image:alt", preview.image.alt],
    ["name", "robots", preview.indexable ? "index, follow" : "noindex"],
  ]
    .map(([attr, key, value]) => `<meta ${attr}="${key}" content="${escapeHtml(value ?? "")}" />`)
    .join("\n    ");

  const rewritten = new HTMLRewriter()
    .on("head > title", {
      element(element) {
        element.setInnerContent(title);
      },
    })
    .on('head > meta[name="description"]', {
      element(element) {
        element.setAttribute("content", preview.description);
      },
    })
    .on("head", {
      element(element) {
        element.append(meta, { html: true });
      },
    })
    .transform(shell);

  const headers = new Headers(rewritten.headers);
  // Visibility can change at any time; never let a cache keep a session's tags.
  headers.set("cache-control", "no-cache");
  headers.delete("content-length");
  headers.delete("etag");
  return new Response(rewritten.body, { status: 200, headers });
}

/** The SPA shell for `request` with `find`'s preview, or `fallback` if that fails. */
async function previewPage(
  env: Env,
  request: Request,
  find: () => Promise<Preview>,
  fallback: Preview,
): Promise<Response> {
  const shell = await env.ASSETS.fetch(new URL("/", request.url));
  if (!shell.ok || !shell.headers.get("content-type")?.includes("text/html")) return shell;
  const url = new URL(request.url);
  const preview = await find().catch((err) => {
    // A preview is never worth a failed page: log it and fall back to the generic tags.
    console.error(err);
    return fallback;
  });
  return injectPreview(shell, preview, `${url.origin}${url.pathname}`);
}

export const sessionPreviewPage = new Hono<AppEnv>()
  .get("/s/:id", (c) =>
    previewPage(c.env, c.req.raw, () => sessionPreview(c.env.DB, c.req.param("id")), GENERIC),
  )
  // The route image the tags point to. Anything without one (private, deleted, unknown,
  // not yet processed) redirects to the brand card, so the answer never tells which.
  .get("/s/:id/og.png", async (c) => {
    const id = c.req.param("id").toLowerCase();
    const fallback = () =>
      new Response(null, {
        status: 302,
        headers: { location: BRAND_IMAGE.path, "cache-control": "no-store" },
      });
    if (!UUID.test(id)) return fallback();
    const image = await ogImage(c.env, id, c.req.raw, (work) =>
      c.executionCtx.waitUntil(work),
    ).catch((err) => {
      console.error("Could not serve a route image.", err);
      return null;
    });
    return image ?? fallback();
  })
  // Deeper paths under /s/ also reach the Worker; hand them to the SPA unchanged.
  .get("/s/*", (c) => c.env.ASSETS.fetch(c.req.raw));

export const profilePreviewPage = new Hono<AppEnv>()
  .get("/u/:handle", (c) =>
    previewPage(
      c.env,
      c.req.raw,
      () => profilePreview(c.env.DB, c.req.param("handle")),
      GENERIC_PROFILE,
    ),
  )
  .get("/u/*", (c) => c.env.ASSETS.fetch(c.req.raw));
