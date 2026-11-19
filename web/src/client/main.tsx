import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createRouter, RouterProvider } from "@tanstack/react-router";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { routeTree } from "./routeTree.gen";
import "./styles.css";

const queryClient = new QueryClient();
const router = createRouter({ routeTree, context: { queryClient }, defaultPreload: "intent" });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

// The production build names its one public address (VITE_CANONICAL_ORIGIN); a visit to
// any other host serving it (the workers.dev address) moves to that address, so sign-in
// cookies and Sign in with Apple's registered return URL always match.
const canonical = import.meta.env.VITE_CANONICAL_ORIGIN;
if (canonical && window.location.origin !== canonical) {
  const { pathname, search, hash } = window.location;
  window.location.replace(`${canonical}${pathname}${search}${hash}`);
}

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root element");

createRoot(root).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
