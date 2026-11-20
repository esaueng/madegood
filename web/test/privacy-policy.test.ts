import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { PrivacyPolicy } from "../src/client/components/privacy-policy";

/** Renders the policy at /privacy in a router of its own (the page uses Link). */
async function renderPolicy() {
  const rootRoute = createRootRoute();
  const privacy = createRoute({
    getParentRoute: () => rootRoute,
    path: "/privacy",
    component: PrivacyPolicy,
  });
  const settings = createRoute({ getParentRoute: () => rootRoute, path: "/settings" });
  const support = createRoute({ getParentRoute: () => rootRoute, path: "/support" });
  const router = createRouter({
    routeTree: rootRoute.addChildren([privacy, settings, support]),
    history: createMemoryHistory({ initialEntries: ["/privacy"] }),
  });
  await router.load();
  // Plain text, so phrases match across tags and line breaks.
  return renderToString(createElement(RouterProvider, { router }))
    .replace(/<[^>]+>/g, "")
    .replace(/<!-- -->/g, "")
    .replace(/\s+/g, " ")
    .replace(/&#x27;/g, "'");
}

// Review of #133 at 6250414: the policy must match what the service does.
describe("/privacy", () => {
  it("says Cloudflare keeps sampled request records with the IP for up to 31 days", async () => {
    const text = await renderPolicy();
    expect(text).toContain("Cloudflare processes your IP address");
    expect(text).toMatch(/keeps a sample of those requests, including the IP address.*31 days/);
    expect(text).toContain("Cloudflare's documentation");
  });

  it("names the public profile API as exposing the handle and name", async () => {
    expect(await renderPolicy()).toContain("directly from the public profile API");
  });

  it("describes website privacy zones apart from iPhone sync", async () => {
    expect(await renderPolicy()).toContain(
      "whether or not Sync sessions is on and even if you never use the iPhone app",
    );
  });

  it("says anchor setup uses location before arming and the backup fires on unusable fixes", async () => {
    const text = await renderPolicy();
    expect(text).toContain("Opening the Anchor Alarm screen starts location");
    expect(text).toContain("before you arm anything");
    expect(text).toContain("usable GPS positions stop arriving");
    expect(text).not.toContain("GPS stops updating");
  });

  it("describes all weather as Apple WeatherKit and never names another weather service", async () => {
    const text = await renderPolicy();
    expect(text).not.toMatch(/open-?meteo/i);
    expect(text).not.toContain("90 days");
    expect(text).toContain("asks Apple Weather (WeatherKit) for the hourly wind");
    expect(text).toContain("Apple never sees your IP address or the viewer's for it");
    // WeatherKit allows only temporary caching: wind is fetched on view, never stored.
    expect(text).toContain("When someone views an unlisted or public session");
    expect(text).toContain("for up to 3 hours, in Cloudflare's cache");
    expect(text).toContain("data exports do not include it");
    expect(text).not.toMatch(/stored with the session\. Apple/);
    expect(text).not.toContain("and the wind (below)");
  });
});
