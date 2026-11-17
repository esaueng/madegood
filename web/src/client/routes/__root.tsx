import type { QueryClient } from "@tanstack/react-query";
import { createRootRouteWithContext, Link, Outlet } from "@tanstack/react-router";

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  component: RootLayout,
  notFoundComponent: NotFound,
});

function RootLayout() {
  return (
    <div className="min-h-dvh bg-background text-foreground">
      <header className="mx-auto flex max-w-5xl items-center gap-3 px-4 py-4">
        <Link to="/" className="flex items-center gap-2 font-semibold">
          <img src="/favicon.svg" alt="" className="size-7 rounded-md" />
          MadeGood
        </Link>
      </header>
      <main className="mx-auto max-w-5xl px-4">
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
