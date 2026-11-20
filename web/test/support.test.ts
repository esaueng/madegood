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

  it("does not promise private-forever sessions or export on the watch", async () => {
    // Regression (PR #136 review): new uploads take the account's default visibility,
    // and export controls are on the iPhone.
    const html = await renderSupport();
    expect(html).not.toContain("Every session is private until you change it");
    expect(html).toContain("shared that way automatically");
    expect(html).not.toContain("export sessions on your iPhone and Apple Watch");
  });
});
