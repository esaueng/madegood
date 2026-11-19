import { createFileRoute, redirect } from "@tanstack/react-router";

// The dashboard moved to /sessions; old /app links keep working.
export const Route = createFileRoute("/app/")({
  beforeLoad: () => {
    throw redirect({ to: "/sessions", replace: true });
  },
});
