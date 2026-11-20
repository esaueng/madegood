import type { QueryClient } from "@tanstack/react-query";
import {
  createRootRouteWithContext,
  Link,
  Outlet,
  useNavigate,
  useRouterState,
} from "@tanstack/react-router";
import { useEffect } from "react";
import { Button, buttonVariants } from "@/components/ui/button";
import { signInUrl } from "@/lib/api";
import { useMe, useSignOut } from "@/lib/auth";

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  component: RootLayout,
  notFoundComponent: NotFound,
});

function Account() {
  const { data: me, isPending } = useMe();
  const signOut = useSignOut();
  const navigate = useNavigate();
  const location = useRouterState({ select: (s) => s.location.href });
  if (isPending) return null;
  if (!me) {
    return (
      <a
        href={signInUrl(
          location === "/" || location.startsWith("/signin") ? "/sessions" : location,
        )}
        className={buttonVariants({ size: "sm", variant: "outline" })}
      >
        Sign in
      </a>
    );
  }
  return (
    <div className="flex items-center gap-1 sm:gap-2">
      <Link
        to="/sessions"
        className="rounded-md px-2 py-1 text-sm hover:bg-accent"
        activeProps={{ className: "font-semibold" }}
        activeOptions={{ exact: true }}
      >
        Dashboard
      </Link>
      <Link
        to="/settings"
        className="rounded-md px-2 py-1 text-sm hover:bg-accent"
        activeProps={{ className: "font-semibold" }}
      >
        Settings
      </Link>
      <Button
        size="sm"
        variant="ghost"
        onClick={async () => {
          await signOut();
          await navigate({ to: "/" });
        }}
      >
        Sign out
      </Button>
    </div>
  );
}

/** index.html's description, which every page without its own goes back to. */
const SITE_DESCRIPTION = "Open-source tracking for sailing, paddling, and time on the water.";

/** Pages with their own title and description. */
const PAGE_META: Record<string, { title: string; description: string }> = {
  "/support": {
    title: "Support · MadeGood",
    description:
      "Help with MadeGood on iPhone and Apple Watch: contact, syncing from the watch, accounts, data export and deletion, sharing and permissions.",
  },
};

function RootLayout() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  // The Worker puts a session's or profile's title into /s/:id and /u/:handle (Open Graph);
  // those pages keep it current, and every other page sets its own or the site's.
  useEffect(() => {
    if (pathname.startsWith("/s/") || pathname.startsWith("/u/")) return;
    const page = PAGE_META[pathname];
    document.title = page?.title ?? "MadeGood";
    document
      .querySelector('meta[name="description"]')
      ?.setAttribute("content", page?.description ?? SITE_DESCRIPTION);
  }, [pathname]);
  return (
    <div className="min-h-dvh bg-background text-foreground">
      <header className="mx-auto flex max-w-5xl items-center justify-between gap-3 px-4 py-4">
        <Link to="/" className="flex items-center gap-2 font-semibold">
          <img src="/favicon.svg" alt="" className="size-7 rounded-md" />
          {/* The account links need the room on phones; the logo keeps its accessible name. */}
          <span className="max-[400px]:sr-only">MadeGood</span>
        </Link>
        <Account />
      </header>
      <main className="mx-auto max-w-5xl px-4 pb-16">
        <Outlet />
      </main>
    </div>
  );
}

function NotFound() {
  return (
    <section className="py-24 text-center">
      <h1 className="text-2xl font-semibold">Page not found</h1>
      <p className="mt-2 text-muted-foreground">
        <Link to="/" className="underline">
          Back to the start
        </Link>
      </p>
    </section>
  );
}
