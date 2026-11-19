import { createFileRoute, redirect } from "@tanstack/react-router";

// The dashboard moved to /sessions; old /app links keep working.
export const Route = createFileRoute("/app/")({
  // Keeps the query string and fragment of old links.
  beforeLoad: ({ location }) => {
    throw redirect({
      to: "/sessions",
      search: location.search,
      hash: location.hash,
      replace: true,
    });
  },
});
