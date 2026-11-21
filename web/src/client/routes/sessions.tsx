import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { Button, buttonVariants } from "@/components/ui/button";
import { VISIBILITY } from "@/components/visibility";
import { fetchSessions, fetchStats, type Session, signInUrl, type Units } from "@/lib/api";
import { useMe } from "@/lib/auth";
import {
  formatDate,
  formatDistance,
  formatDuration,
  formatSpeed,
  SPORT_NAMES,
  sessionTitle,
} from "@/lib/format";

export const Route = createFileRoute("/sessions")({
  component: Dashboard,
});

function Dashboard() {
  const { data: me, isPending } = useMe();
  if (isPending) return <p className="py-16 text-muted-foreground">Loading…</p>;
  if (!me) {
    return (
      <section className="mx-auto max-w-sm py-16 text-center">
        <h1 className="text-2xl font-semibold">Your sessions</h1>
        <p className="mt-2 text-muted-foreground">Sign in to see the sessions you synced.</p>
        <a href={signInUrl("/sessions")} className={buttonVariants({ className: "mt-6" })}>
          Sign in with Apple
        </a>
      </section>
    );
  }
  return (
    <div className="py-6">
      <h1 className="text-2xl font-semibold">
        {me.displayName ? `${me.displayName}'s sessions` : "Your sessions"}
      </h1>
      <Totals units={me.units} />
      <SessionList units={me.units} />
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border bg-card p-4">
      <div className="text-xs text-muted-foreground uppercase tracking-wide">{label}</div>
      <div className="mt-1 text-xl font-semibold tabular-nums">{value}</div>
    </div>
  );
}

function Totals({ units }: { units: Units }) {
  const { data } = useQuery({ queryKey: ["me", "stats"], queryFn: fetchStats });
  if (!data) return <div className="mt-4 h-20" />;
  return (
    <section className="mt-4" aria-label="Totals">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Sessions" value={String(data.sessions)} />
        <Stat label="Distance" value={formatDistance(data.distanceM, units)} />
        <Stat label="Moving time" value={formatDuration(data.movingS)} />
        <Stat label="Total time" value={formatDuration(data.durationS)} />
      </div>
      {data.bySport.length > 1 && (
        <ul className="mt-3 flex flex-wrap gap-2 text-sm text-muted-foreground">
          {data.bySport.map((s) => (
            <li key={s.sport} className="rounded-full border px-3 py-1">
              {SPORT_NAMES[s.sport]}: {s.sessions} · {formatDistance(s.distanceM, units)}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function SessionRow({ session, units }: { session: Session; units: Units }) {
  const Icon = VISIBILITY[session.visibility].icon;
  return (
    <li>
      <Link
        to="/s/$id"
        params={{ id: session.id }}
        className="flex flex-col gap-1 rounded-xl border bg-card p-4 transition-colors hover:bg-accent sm:flex-row sm:items-center sm:justify-between"
      >
        <div className="min-w-0">
          <div className="flex items-center gap-2 font-medium">
            <span className="truncate">{sessionTitle(session)}</span>
            <Icon
              className="size-3.5 shrink-0 text-muted-foreground"
              aria-label={VISIBILITY[session.visibility].label}
            />
          </div>
          <div className="text-sm text-muted-foreground">
            {SPORT_NAMES[session.sport]} · {formatDate(session.startedAt)}
          </div>
        </div>
        <div className="flex gap-4 text-sm tabular-nums">
          <span>{formatDistance(session.distanceM, units)}</span>
          <span>{formatDuration(session.durationS)}</span>
          <span className="hidden sm:inline">{formatSpeed(session.maxSpeedMps, units)}</span>
        </div>
      </Link>
    </li>
  );
}

function SessionList({ units }: { units: Units }) {
  const query = useInfiniteQuery({
    queryKey: ["sessions"],
    queryFn: ({ pageParam }) => fetchSessions(pageParam),
    initialPageParam: null as string | null,
    getNextPageParam: (last) => last.nextCursor,
  });
  if (query.isPending) return <p className="mt-8 text-muted-foreground">Loading sessions…</p>;
  if (query.isError) return <p className="mt-8">Could not load sessions.</p>;
  const sessions = query.data.pages.flatMap((page) => page.sessions);
  if (sessions.length === 0) {
    return (
      <p className="mt-8 rounded-xl border border-dashed p-8 text-center text-muted-foreground">
        No sessions yet. Record one on your Apple Watch or iPhone and turn on sync.
      </p>
    );
  }
  return (
    <section className="mt-8" aria-label="Sessions">
      <ul className="grid gap-2">
        {sessions.map((session) => (
          <SessionRow key={session.id} session={session} units={units} />
        ))}
      </ul>
      {query.hasNextPage && (
        <div className="mt-4 text-center">
          <Button
            variant="outline"
            onClick={() => query.fetchNextPage()}
            disabled={query.isFetchingNextPage}
          >
            {query.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}
    </section>
  );
}
