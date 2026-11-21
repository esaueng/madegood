import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { Pause, Play } from "lucide-react";
import { lazy, Suspense, useEffect, useMemo, useRef, useState } from "react";
import { SPEED_COLORS } from "@/components/session/colors";
import { Button } from "@/components/ui/button";
import { VISIBILITY } from "@/components/visibility";
import {
  ApiError,
  apiFetch,
  fetchSession,
  type Session,
  type Units,
  updateSession,
  type Visibility,
} from "@/lib/api";
import { useMe } from "@/lib/auth";
import {
  formatDate,
  formatDistance,
  formatDuration,
  formatSpeed,
  SPORT_NAMES,
  sessionTitle,
  speedUnit,
  toSpeed,
} from "@/lib/format";
import {
  fetchTrack,
  heartRateAt,
  MANEUVER_TYPES,
  positionAt,
  speedScaleMax,
  type Track,
  TrackTooLargeError,
  trackForViewer,
} from "@/lib/track";

// MapLibre and Recharts are large; load them only on this page, after the stats.
const TrackMap = lazy(() => import("@/components/session/track-map"));
const SessionCharts = lazy(() => import("@/components/session/charts"));

export const Route = createFileRoute("/s/$id")({
  component: SessionPage,
});

const num = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;

function SessionPage() {
  const { id } = Route.useParams();
  const { data: me } = useMe();
  const units: Units = me?.units ?? "nautical";
  const session = useQuery({
    queryKey: ["session", id],
    queryFn: () => fetchSession(id),
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 2,
  });
  const track = useQuery({
    queryKey: ["session", id, "track"],
    queryFn: () => fetchTrack(apiFetch, id),
    retry: (count, error) => !(error instanceof TrackTooLargeError) && count < 2,
    enabled: session.data?.hasTrack === true,
    staleTime: Number.POSITIVE_INFINITY,
  });

  useEffect(() => {
    if (session.data) document.title = `${sessionTitle(session.data)} · MadeGood`;
    else if (session.isError) document.title = "MadeGood";
  }, [session.data, session.isError]);

  if (session.isPending) return <p className="py-16 text-muted-foreground">Loading…</p>;
  if (session.isError) {
    const missing = session.error instanceof ApiError && session.error.status === 404;
    return (
      <section className="py-24 text-center">
        <h1 className="text-2xl font-semibold">
          {missing ? "Session not found" : "Could not load this session"}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {missing
            ? "It may be private, deleted, or the link may be wrong."
            : "Try again in a moment."}
        </p>
        {missing && !me && (
          <p className="mt-4 text-sm">
            <Link to="/signin" search={{ next: `/s/${id}` }} className="underline">
              Sign in
            </Link>{" "}
            if it is yours.
          </p>
        )}
      </section>
    );
  }

  const s = session.data;
  return (
    <article className="grid gap-6 py-6">
      <Header session={s} showProfile={!session.isFetching} />
      <Stats session={s} units={units} />
      {s.hasTrack ? (
        track.isPending ? (
          <div className="h-72 animate-pulse rounded-xl border bg-muted sm:h-[28rem]" />
        ) : track.data ? (
          <Replay source={track.data} isOwner={s.isOwner} units={units} />
        ) : (
          <p className="rounded-xl border border-dashed p-6 text-center text-muted-foreground">
            {track.error instanceof TrackTooLargeError
              ? "This track is too long to show to anyone but its owner."
              : track.isError
                ? "The track could not be loaded."
                : "The track is not available."}
          </p>
        )
      ) : (
        <p className="rounded-xl border border-dashed p-6 text-center text-muted-foreground">
          No track has been uploaded for this session yet.
        </p>
      )}
      <SpeedBests session={s} units={units} />
      {s.wind?.source === "weatherkit" && <SessionWind wind={s.wind} units={units} />}
      {track.data && <Maneuvers track={track.data} />}
      <Laps session={s} units={units} />
      {s.notes && (
        <section>
          <h2 className="mb-2 font-semibold">Notes</h2>
          <p className="whitespace-pre-wrap text-sm">{s.notes}</p>
        </section>
      )}
    </article>
  );
}

function Header({ session, showProfile }: { session: Session; showProfile: boolean }) {
  const queryClient = useQueryClient();
  const change = useMutation({
    mutationFn: (visibility: Visibility) => updateSession(session.id, { visibility }),
    onSuccess: (updated) => {
      const key = ["session", session.id];
      // PATCH updates visibility. The detail view refreshes the wind for shared sessions.
      queryClient.setQueryData<Session>(key, (previous) => ({
        ...updated,
        wind: updated.visibility === "private" ? null : (previous?.wind ?? null),
      }));
      queryClient.invalidateQueries({ queryKey: key, exact: true });
      queryClient.invalidateQueries({ queryKey: ["sessions"] });
      queryClient.invalidateQueries({ queryKey: ["profile"] });
    },
  });
  const current = VISIBILITY[session.visibility];
  const owner = showProfile && session.visibility === "public" ? session.owner : null;
  return (
    <header className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        <h1 className="truncate text-2xl font-semibold sm:text-3xl">{sessionTitle(session)}</h1>
        <p className="wrap-anywhere text-muted-foreground">
          {SPORT_NAMES[session.sport]} · {formatDate(session.startedAt)}
          {owner && (
            <>
              {owner.displayName ? " · by " : " · "}
              <Link
                to="/u/$profileKey"
                params={{ profileKey: owner.profileKey }}
                className="text-primary underline underline-offset-4"
              >
                {owner.displayName ?? "Public profile"}
              </Link>
            </>
          )}
        </p>
      </div>
      {session.isOwner ? (
        <label className="flex shrink-0 items-center gap-2 text-sm">
          <span className="text-muted-foreground">Visibility</span>
          <select
            className="h-9 rounded-md border bg-background px-2"
            value={session.visibility}
            disabled={change.isPending}
            onChange={(event) => change.mutate(event.target.value as Visibility)}
            title={current.hint}
          >
            {(Object.keys(VISIBILITY) as Visibility[]).map((v) => (
              <option key={v} value={v}>
                {VISIBILITY[v].label}
              </option>
            ))}
          </select>
          {change.isError && <span className="text-red-600">Not saved</span>}
        </label>
      ) : (
        <span className="inline-flex shrink-0 items-center gap-1.5 self-start rounded-full border px-3 py-1 text-sm text-muted-foreground sm:self-auto">
          <current.icon className="size-3.5" aria-hidden />
          {current.label}
        </span>
      )}
    </header>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border bg-card p-3">
      <dt className="text-xs text-muted-foreground uppercase tracking-wide">{label}</dt>
      <dd className="mt-0.5 text-lg font-semibold tabular-nums">{value}</dd>
    </div>
  );
}

function Stats({ session, units }: { session: Session; units: Units }) {
  const summary = session.summary ?? {};
  const max2 = num(summary.maxSpeed2s) ?? session.maxSpeedMps;
  const max10 = num(summary.maxSpeed10s);
  const hrAvg = num(summary.heartRateAverage);
  const hrMax = num(summary.heartRateMax);
  return (
    <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <Stat label="Distance" value={formatDistance(session.distanceM, units)} />
      <Stat label="Moving time" value={formatDuration(session.movingS)} />
      <Stat label="Total time" value={formatDuration(session.durationS)} />
      <Stat label="Avg speed" value={formatSpeed(session.avgSpeedMps, units)} />
      <Stat label="Max speed (2 s)" value={formatSpeed(max2, units)} />
      {max10 !== null && <Stat label="Max speed (10 s)" value={formatSpeed(max10, units)} />}
      {hrAvg !== null && <Stat label="Avg heart rate" value={`${Math.round(hrAvg)} bpm`} />}
      {hrMax !== null && <Stat label="Max heart rate" value={`${Math.round(hrMax)} bpm`} />}
    </dl>
  );
}

function SessionWind({ wind, units }: { wind: NonNullable<Session["wind"]>; units: Units }) {
  const direction =
    wind.directionDeg === null ? "–" : `${Math.round(wind.directionDeg) % 360}° true`;
  return (
    <section aria-labelledby="session-wind">
      <h2 id="session-wind" className="mb-2 font-semibold">
        Modelled wind
      </h2>
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="From" value={direction} />
        <Stat label="Avg wind speed" value={formatSpeed(wind.speedMps, units)} />
        {wind.gustMps !== null && (
          <Stat label="Peak gust" value={formatSpeed(wind.gustMps, units)} />
        )}
      </dl>
      <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
        <a
          href="https://developer.apple.com/weatherkit/data-source-attribution/"
          className="inline-flex rounded-sm py-1 focus-visible:outline-2 focus-visible:outline-ring"
        >
          <picture>
            <source media="(prefers-color-scheme: dark)" srcSet="/apple-weather-dark.png" />
            <img
              src="/apple-weather-light.png"
              alt="Apple Weather attribution"
              width={77}
              height={14}
            />
          </picture>
        </a>
        <span>Not for navigation.</span>
      </div>
    </section>
  );
}

const RATES = [10, 30, 60, 120];

function Replay({ source, isOwner, units }: { source: Track; isOwner: boolean; units: Units }) {
  // Heart rate is the owner's alone; memoized so the map and charts keep their caches.
  const track = useMemo(() => trackForViewer(source, isOwner), [source, isOwner]);
  const [cursorT, setCursorT] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [rate, setRate] = useState(30);
  const maxSpeed = useMemo(() => speedScaleMax(track.fixes), [track]);
  const cursor = useMemo(() => positionAt(track, cursorT), [track, cursorT]);
  const hr = heartRateAt(track.hr, cursorT);
  const frame = useRef<number | null>(null);

  useEffect(() => {
    if (!playing) return;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = ((now - last) / 1000) * rate;
      last = now;
      setCursorT((t) => {
        const next = t + dt;
        if (next >= track.endT) {
          setPlaying(false);
          return track.endT;
        }
        return next;
      });
      frame.current = requestAnimationFrame(tick);
    };
    frame.current = requestAnimationFrame(tick);
    return () => {
      if (frame.current !== null) cancelAnimationFrame(frame.current);
    };
  }, [playing, rate, track.endT]);

  if (track.fixes.length === 0) {
    return (
      <p className="rounded-xl border border-dashed p-6 text-center text-muted-foreground">
        This track has no positions to show.
      </p>
    );
  }
  return (
    <section className="grid gap-4" aria-label="Map and replay">
      <Suspense
        fallback={<div className="h-72 animate-pulse rounded-xl border bg-muted sm:h-[28rem]" />}
      >
        <TrackMap track={track} maxSpeed={maxSpeed} cursor={cursor} isOwner={isOwner} />
      </Suspense>
      <SpeedLegend maxSpeed={maxSpeed} units={units} />
      <div className="flex flex-wrap items-center gap-3 rounded-xl border bg-card p-3">
        <Button
          size="icon"
          variant="outline"
          aria-label={playing ? "Pause replay" : "Play replay"}
          onClick={() => {
            if (!playing && cursorT >= track.endT) setCursorT(0);
            setPlaying(!playing);
          }}
        >
          {playing ? <Pause /> : <Play />}
        </Button>
        <input
          type="range"
          aria-label="Replay position"
          className="min-w-40 flex-1 accent-[var(--primary)]"
          min={0}
          max={track.endT}
          step={0.5}
          value={cursorT}
          onChange={(event) => setCursorT(Number(event.target.value))}
        />
        <select
          aria-label="Replay speed"
          className="h-9 rounded-md border bg-background px-2 text-sm"
          value={rate}
          onChange={(event) => setRate(Number(event.target.value))}
        >
          {RATES.map((r) => (
            <option key={r} value={r}>
              {r}×
            </option>
          ))}
        </select>
        <div className="flex w-full gap-4 text-sm tabular-nums sm:w-auto">
          <span>{formatDuration(cursorT)}</span>
          <span>{cursor?.spd != null ? formatSpeed(cursor.spd, units) : "–"}</span>
          {hr !== null && <span>{Math.round(hr)} bpm</span>}
        </div>
      </div>
      <Suspense fallback={null}>
        <SessionCharts track={track} units={units} cursorT={cursorT} onSeek={setCursorT} />
      </Suspense>
    </section>
  );
}

function SpeedLegend({ maxSpeed, units }: { maxSpeed: number; units: Units }) {
  return (
    <div className="flex items-center gap-2 text-xs text-muted-foreground">
      <span>0</span>
      <span
        className="h-2 flex-1 rounded-full sm:max-w-64"
        style={{ background: `linear-gradient(to right, ${SPEED_COLORS.join(", ")})` }}
      />
      <span>
        {toSpeed(maxSpeed, units).toFixed(1)}+ {speedUnit(units)}
      </span>
    </div>
  );
}

const BESTS: [key: string, label: string][] = [
  ["best5x10s", "5 × 10 s"],
  ["best100m", "100 m"],
  ["best500m", "500 m"],
  ["bestNauticalMile", "Nautical mile"],
  ["best1h", "1 hour"],
  ["alpha500", "Alpha 500"],
];

function SpeedBests({ session, units }: { session: Session; units: Units }) {
  const summary = session.summary ?? {};
  const bests = BESTS.flatMap(([key, label]) => {
    const value = num(summary[key]);
    return value === null ? [] : [{ key, label, value }];
  });
  if (bests.length === 0) return null;
  return (
    <section>
      <h2 className="mb-2 font-semibold">Speed bests</h2>
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {bests.map((b) => (
          <Stat key={b.key} label={b.label} value={formatSpeed(b.value, units)} />
        ))}
      </dl>
    </section>
  );
}

function Maneuvers({ track }: { track: Track }) {
  const maneuvers = track.events.filter((e) => MANEUVER_TYPES.has(e.type));
  if (maneuvers.length === 0) return null;
  const count = (type: string) => maneuvers.filter((m) => m.type === type).length;
  return (
    <section>
      <h2 className="mb-2 font-semibold">
        Maneuvers{" "}
        <span className="font-normal text-muted-foreground">
          · {count("tack")} tacks · {count("gybe")} gybes
        </span>
      </h2>
      <ol className="grid max-h-72 gap-1 overflow-y-auto rounded-xl border p-2 text-sm">
        {maneuvers.map((m, i) => {
          const duration = num(m.data?.durationS);
          return (
            // biome-ignore lint/suspicious/noArrayIndexKey: events have no ID and never reorder.
            <li key={`${m.t}-${i}`} className="flex justify-between gap-4 px-2 py-1 tabular-nums">
              <span className="capitalize">{m.type}</span>
              <span className="text-muted-foreground">
                {formatDuration(m.t)}
                {duration !== null && ` · ${duration.toFixed(1)} s`}
              </span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function Laps({ session, units }: { session: Session; units: Units }) {
  const laps = Array.isArray(session.summary?.laps)
    ? (session.summary.laps as Record<string, unknown>[])
    : [];
  if (laps.length === 0) return null;
  return (
    <section>
      <h2 className="mb-2 font-semibold">Laps</h2>
      <div className="overflow-x-auto rounded-xl border">
        <table className="w-full text-sm tabular-nums">
          <thead className="text-left text-muted-foreground">
            <tr>
              <th className="px-3 py-2 font-medium">#</th>
              <th className="px-3 py-2 font-medium">Distance</th>
              <th className="px-3 py-2 font-medium">Moving time</th>
              <th className="px-3 py-2 font-medium">Avg speed</th>
            </tr>
          </thead>
          <tbody>
            {laps.map((lap, i) => {
              const distance = num(lap.distance);
              const moving = num(lap.movingTime);
              const speed = distance !== null && moving ? distance / moving : null;
              return (
                // biome-ignore lint/suspicious/noArrayIndexKey: laps have no ID and never reorder.
                <tr key={i} className="border-t">
                  <td className="px-3 py-2">
                    {i + 1}
                    {lap.auto === true && <span className="ml-1 text-muted-foreground">auto</span>}
                  </td>
                  <td className="px-3 py-2">{formatDistance(distance, units)}</td>
                  <td className="px-3 py-2">{formatDuration(moving)}</td>
                  <td className="px-3 py-2">{formatSpeed(speed, units)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
