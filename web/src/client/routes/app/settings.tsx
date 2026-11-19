import { createFileRoute, redirect } from "@tanstack/react-router";

// Settings moved to /settings; old /app/settings links keep working.
export const Route = createFileRoute("/app/settings")({
  // Keeps the query string and fragment of old links.
  beforeLoad: ({ location }) => {
    throw redirect({
      to: "/settings",
      search: location.search,
      hash: location.hash,
      replace: true,
    });
  },
});
