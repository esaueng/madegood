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
import { questionId, SUPPORT_EMAIL, SupportPage } from "../src/client/components/support-page";

/** Renders the support page at /support in a router of its own (the page uses Link). */
async function renderSupport() {
  const rootRoute = createRootRoute();
  const support = createRoute({
    getParentRoute: () => rootRoute,
    path: "/support",
    component: SupportPage,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([support]),
    history: createMemoryHistory({ initialEntries: ["/support"] }),
  });
  await router.load();
  return renderToString(createElement(RouterProvider, { router }));
}

describe("/support", () => {
  it("renders the page with the contact address as a mailto link", async () => {
    const html = await renderSupport();
    expect(SUPPORT_EMAIL).toBe("support@madegood.app");
    expect(html).toContain("<h1");
    expect(html).toContain("Support</h1>");
    expect(html).toContain('href="mailto:support@madegood.app"');
    expect(html).toContain('href="https://github.com/esaueng/madegood/issues"');
    expect(html).toContain('href="/privacy"');
    expect(html).toContain("Not for navigation");
  });

  it("ignores a malformed fragment instead of throwing", () => {
    // Regression (PR #136 review): "#%" threw URIError in the open-question effect.
    expect(questionId("#%")).toBe("");
    expect(questionId("#delete-account")).toBe("delete-account");
    expect(questionId("")).toBe("");
  });

  it("says sharing is unavailable and does not promise export on the watch", async () => {
    // Regression (PR #136 review): export controls are on the iPhone. Sharing is unavailable
    // for now (src/server/lib/sharing-available.ts), so nothing points to sharing controls.
    const html = await renderSupport();
    expect(html).toContain("Sharing is unavailable, so every synced session is private");
    expect(html).not.toContain("Allow sharing");
    expect(html).not.toContain("Enable public profile");
    expect(html).not.toContain("export sessions on your iPhone and Apple Watch");
  });
});
