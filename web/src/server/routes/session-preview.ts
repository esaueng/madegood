import { and, eq, isNull, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/d1";
import { Hono } from "hono";
import type { AppEnv } from "../app";
import { HANDLE_PATTERN } from "../auth/users";
import { sessions, users } from "../db/schema";

// /s/:id is the SPA's session page. The Worker serves it (wrangler.jsonc
// `run_worker_first`) to put Open Graph tags into the HTML, so shared links preview with
// the session's title and headline stats. Only public and unlisted sessions get them; a
// private, deleted or unknown session gets the same generic tags, so the preview never
// tells whether it exists. Tags never contain positions, bounds or times of day, and
// there is no map image: a static map needs a renderer we do not run yet (PLAN §7 queue).
//
// /u/:handle, the public profile, works the same way: tags only while the profile is
// visible to everyone (routes/users.ts: at least one public session), generic otherwise.

/** `pageTitle` is the document title; without it, `title · MadeGood`. */
type Preview = { title: string; description: string; indexable: boolean; pageTitle?: string };

const SITE = "MadeGood";
const SITE_DESCRIPTION = "Open-source tracking for sailing, paddling, and time on the water.";
const GENERIC: Preview = {
  title: "A session on MadeGood",
  pageTitle: "A session on MadeGood",
  description: SITE_DESCRIPTION,
  indexable: false,
};
const GENERIC_PROFILE: Preview = {
  title: "A profile on MadeGood",
  pageTitle: "A profile on MadeGood",
  description: SITE_DESCRIPTION,
  indexable: false,
};

const SPORT_NAMES = {
  sailing: "Sailing",
  windsurfing: "Windsurfing",
  motorboating: "Motorboating",
  kayak: "Kayak",
  canoe: "Canoe",
  sup: "Stand-up paddle",
} as const;

const UNITS = {
  nautical: { distance: 1 / 1852, distanceUnit: "nm", speed: 3600 / 1852, speedUnit: "kn" },
  metric: { distance: 1 / 1000, distanceUnit: "km", speed: 3.6, speedUnit: "km/h" },
  imperial: {
    distance: 1 / 1609.344,
    distanceUnit: "mi",
    speed: 3600 / 1609.344,
    speedUnit: "mph",
  },
} as const;

const distance = (m: number, units: keyof typeof UNITS) =>
  `${(m * UNITS[units].distance).toFixed(2)} ${UNITS[units].distanceUnit}`;

function duration(s: number): string {
  const total = Math.round(s);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  return h > 0 ? `${h} h ${String(m).padStart(2, "0")} min` : `${m} min`;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The preview for a session ID; GENERIC unless the session is public or unlisted. */
export async function sessionPreview(db: D1Database, id: string): Promise<Preview> {
  if (!UUID.test(id)) return GENERIC;
  const [row] = await drizzle(db)
    .select({
      sport: sessions.sport,
      title: sessions.title,
      visibility: sessions.visibility,
      durationS: sessions.durationS,
      distanceM: sessions.distanceM,
      maxSpeedMps: sessions.maxSpeedMps,
      units: users.units,
    })
    .from(sessions)
    .innerJoin(users, eq(users.id, sessions.userId))
    .where(and(eq(sessions.id, id.toLowerCase()), isNull(sessions.deletedAt)));
  if (!row || row.visibility === "private") return GENERIC;

  const units = UNITS[row.units];
  const sport = SPORT_NAMES[row.sport];
  const parts: string[] = [sport];
  if (row.distanceM != null) {
    parts.push(distance(row.distanceM, row.units));
  }
  if (row.durationS != null) parts.push(duration(row.durationS));
  if (row.maxSpeedMps != null) {
    parts.push(`max ${(row.maxSpeedMps * units.speed).toFixed(1)} ${units.speedUnit}`);
  }
  return {
    title: row.title ?? sport,
    description: parts.join(" · "),
    indexable: row.visibility === "public",
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
  };
}

const escapeHtml = (text: string) =>
  text.replace(
    /[&<>"']/g,
    (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch] ?? ch,
  );

/** The SPA shell with the preview's title, description and Open Graph tags. */
export function injectPreview(shell: Response, preview: Preview, url: string): Response {
  const title = preview.pageTitle ?? `${preview.title} · ${SITE}`;
  const meta = [
    ["property", "og:site_name", SITE],
    ["property", "og:type", "website"],
    ["property", "og:title", preview.title],
    ["property", "og:description", preview.description],
    ["property", "og:url", url],
    ["name", "twitter:card", "summary"],
    ["name", "twitter:title", preview.title],
    ["name", "twitter:description", preview.description],
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
