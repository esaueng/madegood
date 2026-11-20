import { useInfiniteQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { Check, Globe, Link2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  ApiError,
  fetchProfile,
  type MeStats,
  type PublicProfile,
  type PublicSessionSummary,
  type Units,
} from "@/lib/api";
import { useMe } from "@/lib/auth";
import {
  formatDate,
  formatDistance,
  formatDuration,
  formatSpeed,
  SPORT_NAMES,
  sessionTitle,
} from "@/lib/format";

export const Route = createFileRoute("/u/$handle")({
  component: ProfilePage,
});

// A user's public profile. The API lists public sessions only (never unlisted or private
// ones) and answers 404 to everyone but the owner while there are none.

function ProfilePage() {
  const { handle } = Route.useParams();
  const { data: me } = useMe();
  const units: Units = me?.units ?? "nautical";
  const query = useInfiniteQuery({
    queryKey: ["profile", handle.toLowerCase()],
    queryFn: ({ pageParam }) => fetchProfile(handle, pageParam),
    initialPageParam: null as string | null,
    getNextPageParam: (last) => last.nextCursor,
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 2,
  });
  const profile = query.data?.pages[0];

  useEffect(() => {
    if (profile) document.title = `${profileName(profile)} · MadeGood`;
    else if (query.isError) document.title = "MadeGood";
  }, [profile, query.isError]);

  if (query.isPending) return <p className="py-16 text-muted-foreground">Loading…</p>;
  if (query.isError || !profile) {
    const missing = query.error instanceof ApiError && query.error.status === 404;
    return (
      <section className="mx-auto max-w-md py-24 text-center">
        <h1 className="text-2xl font-semibold">
          {missing ? "Profile not found" : "Could not load this profile"}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {missing
            ? "There is no one with this handle, or they have not shared any sessions publicly yet."
            : "Try again in a moment."}
        </p>
        {missing && !me && (
          <p className="mt-4 text-sm">
            <Link to="/signin" search={{ next: `/u/${handle}` }} className="underline">
              Sign in
            </Link>{" "}
            if it is yours.
          </p>
        )}
      </section>
    );
  }

  const sessions = query.data.pages.flatMap((page) => page.sessions);
  return (
    <article className="grid gap-8 py-6">
      <ProfileHeader profile={profile} />
      {profile.isOwner && <OwnerNote count={profile.totals.sessions} />}
      {profile.totals.sessions > 0 && <Totals totals={profile.totals} units={units} />}
      {sessions.length > 0 && (
        <section aria-labelledby="public-sessions">
          <h2 id="public-sessions" className="mb-3 text-lg font-semibold">
            Public sessions
          </h2>
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
      )}
    </article>
  );
}

const profileName = (profile: PublicProfile) => profile.displayName ?? `@${profile.handle}`;

/** Up to two initials from the display name, or the handle's first letter. */
function initials(profile: PublicProfile): string {
  const words = (profile.displayName ?? "").trim().split(/\s+/).filter(Boolean);
  const letters = words.length > 0 ? words.slice(0, 2).map((w) => w[0]) : [profile.handle[0]];
  return letters.join("").toUpperCase();
}

function ProfileHeader({ profile }: { profile: PublicProfile }) {
  const sports = profile.totals.bySport.map((s) => s.sport);
  return (
    <header className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex min-w-0 items-center gap-4">
        <div
          aria-hidden
          className="grid size-16 shrink-0 place-items-center rounded-full bg-primary text-xl font-semibold text-primary-foreground sm:size-20 sm:text-2xl"
        >
          {initials(profile)}
        </div>
        <div className="min-w-0">
          <h1 className="truncate text-2xl font-semibold sm:text-3xl">{profileName(profile)}</h1>
          {profile.displayName && (
            <p className="truncate text-muted-foreground">@{profile.handle}</p>
          )}
          {sports.length > 0 && (
            <ul className="mt-2 flex flex-wrap gap-1.5" aria-label="Sports">
              {sports.map((sport) => (
                <li
                  key={sport}
                  className="rounded-full bg-secondary px-2.5 py-0.5 text-xs font-medium text-secondary-foreground"
                >
                  {SPORT_NAMES[sport]}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
      {/* Nobody else can open a profile without public sessions; nothing to share yet. */}
      {profile.totals.sessions > 0 && <CopyLink />}
    </header>
  );
}

function CopyLink() {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 2000);
    return () => clearTimeout(timer);
  }, [copied]);
  if (!navigator.clipboard) return null;
  return (
    <Button
      variant="outline"
      size="sm"
      className="self-start sm:self-auto"
      onClick={async () => {
        await navigator.clipboard.writeText(window.location.href.split(/[?#]/)[0] ?? "");
        setCopied(true);
      }}
    >
      {copied ? <Check aria-hidden /> : <Link2 aria-hidden />}
      <span aria-live="polite">{copied ? "Link copied" : "Copy link"}</span>
    </Button>
  );
}

function OwnerNote({ count }: { count: number }) {
  return (
    <aside className="flex gap-3 rounded-xl border border-primary/30 bg-primary/5 p-4 text-sm">
      <Globe className="mt-0.5 size-4 shrink-0 text-primary" aria-hidden />
      <div>
        <p className="font-medium">This is your public profile</p>
        <p className="mt-1 text-muted-foreground">
          {count > 0
            ? "Anyone can see your name, handle and the sessions below, which are the ones you made public. Private and unlisted sessions never appear here."
            : "Only you can see this page until you make a session public. Private and unlisted sessions never appear here."}{" "}
          Change a session's visibility from its page on your{" "}
          <Link to="/sessions" className="underline">
            dashboard
          </Link>
          .
        </p>
      </div>
    </aside>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border bg-card p-4">
      <dt className="text-xs text-muted-foreground uppercase tracking-wide">{label}</dt>
      <dd className="mt-1 text-xl font-semibold tabular-nums">{value}</dd>
    </div>
  );
}

function Totals({ totals, units }: { totals: MeStats; units: Units }) {
  return (
    <section aria-label="Totals" className="grid gap-3">
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="Sessions" value={String(totals.sessions)} />
        <Stat label="Distance" value={formatDistance(totals.distanceM, units)} />
        <Stat label="Moving time" value={formatDuration(totals.movingS)} />
        <Stat label="Total time" value={formatDuration(totals.durationS)} />
      </dl>
      {totals.bySport.length > 1 && (
        <ul className="divide-y rounded-xl border" aria-label="Totals by sport">
          {totals.bySport.map((s) => (
            <li key={s.sport} className="flex items-baseline gap-3 px-4 py-2.5 text-sm">
              <span className="min-w-0 flex-1 truncate font-medium">{SPORT_NAMES[s.sport]}</span>
              <span className="text-muted-foreground tabular-nums">
                {s.sessions} {s.sessions === 1 ? "session" : "sessions"}
              </span>
              <span className="w-20 text-right font-medium tabular-nums">
                {formatDistance(s.distanceM, units)}
              </span>
              <span className="hidden w-20 text-right text-muted-foreground tabular-nums sm:inline">
                {formatDuration(s.movingS)}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function SessionRow({ session, units }: { session: PublicSessionSummary; units: Units }) {
  return (
    <li>
      <Link
        to="/s/$id"
        params={{ id: session.id }}
        className="flex flex-col gap-1 rounded-xl border bg-card p-4 transition-colors hover:bg-accent sm:flex-row sm:items-center sm:justify-between"
      >
        <div className="min-w-0">
          <div className="truncate font-medium">{sessionTitle(session)}</div>
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
