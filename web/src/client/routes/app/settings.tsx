import { createFileRoute, redirect } from "@tanstack/react-router";

// Settings moved to /settings; old /app/settings links keep working.
export const Route = createFileRoute("/app/settings")({
  beforeLoad: () => {
    throw redirect({ to: "/settings", replace: true });
  },
});
