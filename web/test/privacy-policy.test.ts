import { isValidElement, type ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { PrivacyPolicy } from "../src/client/components/privacy-policy";

/**
 * The policy's text, read from its React element tree rather than from rendered HTML, so
 * phrases match across tags and line breaks without parsing markup. Function components
 * (the page's sections) are called; anything else (elements, Link) contributes its children.
 */
function textOf(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (isValidElement<{ children?: ReactNode }>(node)) {
    const { type, props } = node;
    if (typeof type === "function") {
      return textOf((type as (p: typeof props) => ReactNode)(props));
    }
    return textOf(props.children);
  }
  return "";
}

async function renderPolicy() {
  return textOf(PrivacyPolicy()).replace(/\s+/g, " ");
}

/** The link targets in the policy, for checking where its history links point. */
function hrefsOf(node: ReactNode): string[] {
  if (Array.isArray(node)) return node.flatMap(hrefsOf);
  if (!isValidElement<{ children?: ReactNode; href?: string }>(node)) return [];
  const { type, props } = node;
  if (typeof type === "function") return hrefsOf((type as (p: typeof props) => ReactNode)(props));
  return [...(props.href ? [props.href] : []), ...hrefsOf(props.children)];
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

  // Review of #133 at 547913b.
  it("says sign-in reaches the server before an account exists and what it stores", async () => {
    const text = await renderPolicy();
    expect(text).toContain("The apps send nothing to MadeGood until you try to sign in");
    expect(text).not.toContain("Without an account, nothing reaches MadeGood");
    expect(text).toContain("sends MadeGood's server, through Cloudflare");
    expect(text).toContain("before any account exists, and also when signing in then fails");
    expect(text).toContain("stores the following even if you never turn on sync");
    expect(text).toContain("storing a hash of its refresh token");
    expect(text).toContain("Visibility of new sessions, which starts at Private");
  });

  // Review of #133 at 58ed722: the account record is written before tokens are issued.
  it("says a sign-in failing after account creation can leave the account record", async () => {
    const text = await renderPolicy();
    expect(text).not.toMatch(
      /If the sign-in fails, MadeGood stores nothing|failed sign-in stores nothing/,
    );
    expect(text).toContain("the confirmation is not valid, there were too many attempts");
    expect(text).toContain("can still leave the account record");
    expect(text).toContain("MadeGood does not remove such a record on its own");
  });

  it("does not say the iPhone shows or checks Visibility of new sessions", async () => {
    const text = await renderPolicy();
    expect(text).not.toContain("The iPhone checks that setting");
    expect(text).not.toMatch(/last checked/i);
  });

  it("describes the iPhone weather cache as merged in #141", async () => {
    const text = await renderPolicy();
    expect(text).toContain("refresh automatically every 15 minutes");
    expect(text).toContain("turning them on or refreshing by hand fetches them at once");
    expect(text).toContain(
      "reuses current conditions for up to 15 minutes, forecast wind for up to 1 hour and past wind for up to 24 hours",
    );
    // Reuse periods, not retention: expired entries wait for cleanup or iOS (review at 58ed722).
    expect(text).toContain("stays in the cache until the app's cleanup removes it");
    expect(text).toContain("when the app starts and each time it returns to the foreground");
    expect(text).toContain("updating the app removes them");
    expect(text).not.toContain("at most every 15 minutes");
  });

  it("promises automatic deletion retries without an interval the code can't keep", async () => {
    const text = await renderPolicy();
    expect(text).toContain("tries again automatically, waiting longer after each failure");
    expect(text).not.toMatch(/every 6 hours|six hours/);
    // 20 minutes is the minimum grace period, not a completion time (review at 58ed722).
    expect(text).not.toContain("About 20 minutes after your request");
    expect(text).toContain("no sooner than 20 minutes after your request");
    expect(text).toContain("only once that cleanup has succeeded");
    expect(text).toContain("every sign-in ends and the account is locked");
  });

  it("links the history of both the old route file and the component", () => {
    const hrefs = hrefsOf(PrivacyPolicy());
    expect(hrefs).toContain(
      "https://github.com/esaueng/madegood/commits/main/web/src/client/components/privacy-policy.tsx",
    );
    expect(hrefs).toContain(
      "https://github.com/esaueng/madegood/commits/main/web/src/client/routes/privacy.tsx",
    );
  });
});
