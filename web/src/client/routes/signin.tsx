import { createFileRoute } from "@tanstack/react-router";
import { buttonVariants } from "@/components/ui/button";
import { signInUrl } from "@/lib/api";
import { cn } from "@/lib/utils";

type Search = { error?: string; next?: string };

export const Route = createFileRoute("/signin")({
  validateSearch: (search: Record<string, unknown>): Search => ({
    error: typeof search.error === "string" ? search.error : undefined,
    next: typeof search.next === "string" ? search.next : undefined,
  }),
  component: SignIn,
});

const MESSAGES: Record<string, string> = {
  cancelled: "Sign-in was cancelled.",
  expired: "The sign-in took too long or was started in another tab. Try again.",
  invalid: "Apple's response could not be verified. Try again.",
  unavailable: "Web sign-in is not set up on this server yet.",
};

function SignIn() {
  const { error, next } = Route.useSearch();
  return (
    <section className="mx-auto max-w-sm py-16 text-center">
      <h1 className="text-2xl font-semibold">Sign in</h1>
      <p className="mt-2 text-muted-foreground">
        Use the Apple ID you use in the MadeGood app to see your synced sessions.
      </p>
      {error && (
        <p role="alert" className="mt-4 rounded-md border border-red-500/40 p-3 text-sm">
          {MESSAGES[error] ?? "Sign-in failed. Try again."}
        </p>
      )}
      <a
        href={signInUrl(next ?? "/sessions")}
        className={cn(
          buttonVariants({ size: "lg" }),
          "mt-6 bg-black text-white hover:bg-black/85 dark:bg-white dark:text-black dark:hover:bg-white/85",
        )}
      >
        Sign in with Apple
      </a>
    </section>
  );
}
