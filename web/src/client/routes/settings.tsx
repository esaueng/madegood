import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Download, LocateFixed, Trash2, TriangleAlert } from "lucide-react";
import { lazy, Suspense, useState } from "react";
import { Button, buttonVariants } from "@/components/ui/button";
import { VISIBILITY } from "@/components/visibility";
import type { Draft } from "@/components/zone-map";
import {
  ApiError,
  addZone,
  deleteZone,
  fetchLatestExport,
  fetchZones,
  type Me,
  signInUrl,
  startExport,
  type Units,
  updateMe,
  type Visibility,
} from "@/lib/api";
import { meQueryKey, useDeleteAccount, useMe } from "@/lib/auth";

const ZoneMap = lazy(() => import("@/components/zone-map"));

export const Route = createFileRoute("/settings")({
  component: Settings,
});

const UNIT_LABELS: Record<Units, string> = {
  nautical: "Nautical (kn, nm)",
  metric: "Metric (km/h, km)",
  imperial: "Imperial (mph, mi)",
};

function Settings() {
  const { data: me, isPending } = useMe();
  const [deleted, setDeleted] = useState(false);
  if (deleted) {
    return (
      <section className="mx-auto max-w-sm py-16 text-center" role="status">
        <h1 className="text-2xl font-semibold">Account deleted</h1>
        <p className="mt-2 text-muted-foreground">
          Your MadeGood account and everything you uploaded to it are gone. Sessions on your iPhone
          and Apple Watch are still there.
        </p>
      </section>
    );
  }
  if (isPending) return <p className="py-16 text-muted-foreground">Loading…</p>;
  if (!me) {
    return (
      <section className="mx-auto max-w-sm py-16 text-center">
        <h1 className="text-2xl font-semibold">Settings</h1>
        <p className="mt-2 text-muted-foreground">Sign in to change your settings.</p>
        <a href={signInUrl("/settings")} className={buttonVariants({ className: "mt-6" })}>
          Sign in with Apple
        </a>
      </section>
    );
  }
  return (
    <div className="grid gap-10 py-6">
      <h1 className="text-2xl font-semibold">Settings</h1>
      <Preferences me={me} />
      <Zones />
      <ExportData />
      <DeleteAccount me={me} onDeleted={() => setDeleted(true)} />
    </div>
  );
}

function Preferences({ me }: { me: Me }) {
  const queryClient = useQueryClient();
  const save = useMutation({
    mutationFn: updateMe,
    onSuccess: (updated) => queryClient.setQueryData(meQueryKey, updated),
  });
  return (
    <section className="grid gap-4 sm:max-w-md">
      <label className="grid gap-1 text-sm">
        <span className="font-medium">Units</span>
        <select
          className="h-9 rounded-md border bg-background px-2"
          value={me.units}
          disabled={save.isPending}
          onChange={(e) => save.mutate({ units: e.target.value as Units })}
        >
          {(Object.keys(UNIT_LABELS) as Units[]).map((u) => (
            <option key={u} value={u}>
              {UNIT_LABELS[u]}
            </option>
          ))}
        </select>
      </label>
      <label className="grid gap-1 text-sm">
        <span className="font-medium">Visibility of new sessions</span>
        <select
          className="h-9 rounded-md border bg-background px-2"
          value={me.defaultVisibility}
          disabled={save.isPending}
          onChange={(e) => save.mutate({ defaultVisibility: e.target.value as Visibility })}
        >
          {(Object.keys(VISIBILITY) as Visibility[]).map((v) => (
            <option key={v} value={v}>
              {VISIBILITY[v].label}: {VISIBILITY[v].hint}
            </option>
          ))}
        </select>
      </label>
      {save.isError && <p className="text-sm text-red-600">Could not save. Try again.</p>}
    </section>
  );
}

const RADII = [100, 200, 500, 1000, 2000, 5000];

function Zones() {
  const queryClient = useQueryClient();
  const zones = useQuery({ queryKey: ["me", "zones"], queryFn: fetchZones });
  const [draft, setDraft] = useState<Draft | null>(null);
  const [locating, setLocating] = useState(false);
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["me", "zones"] });
  const add = useMutation({
    mutationFn: addZone,
    onSuccess: () => {
      setDraft(null);
      refresh();
    },
  });
  const remove = useMutation({ mutationFn: deleteZone, onSuccess: refresh });
  const pick = (lat: number, lon: number) =>
    setDraft((d) => ({ lat, lon, radiusM: d?.radiusM ?? 500 }));

  return (
    <section className="grid gap-4">
      <div>
        <h2 className="text-lg font-semibold">Privacy zones</h2>
        <p className="mt-1 max-w-prose text-sm text-muted-foreground">
          Hide the parts of your tracks near home or your usual launch spots. Anyone else who opens
          a shared or public session sees the track with these areas cut out. You always see your
          whole track. Click the map to place a zone.
        </p>
      </div>
      <Suspense
        fallback={<div className="h-80 animate-pulse rounded-xl border bg-muted sm:h-96" />}
      >
        <ZoneMap zones={zones.data ?? []} draft={draft} onPick={pick} />
      </Suspense>
      <div className="flex flex-wrap items-center gap-3">
        <Button
          variant="outline"
          size="sm"
          disabled={locating || !("geolocation" in navigator)}
          onClick={() => {
            setLocating(true);
            navigator.geolocation.getCurrentPosition(
              (p) => {
                setLocating(false);
                pick(p.coords.latitude, p.coords.longitude);
              },
              () => setLocating(false),
              { enableHighAccuracy: false, timeout: 10_000 },
            );
          }}
        >
          <LocateFixed /> {locating ? "Locating…" : "Use my location"}
        </Button>
        {draft && (
          <>
            <label className="flex items-center gap-2 text-sm">
              Radius
              <select
                className="h-8 rounded-md border bg-background px-2"
                value={draft.radiusM}
                onChange={(e) => setDraft({ ...draft, radiusM: Number(e.target.value) })}
              >
                {RADII.map((r) => (
                  <option key={r} value={r}>
                    {r < 1000 ? `${r} m` : `${r / 1000} km`}
                  </option>
                ))}
              </select>
            </label>
            <Button size="sm" disabled={add.isPending} onClick={() => add.mutate(draft)}>
              Add zone
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setDraft(null)}>
              Cancel
            </Button>
          </>
        )}
        {add.isError && <span className="text-sm text-red-600">{add.error.message}</span>}
      </div>
      {zones.data && zones.data.length > 0 ? (
        <ul className="grid gap-2">
          {zones.data.map((zone, i) => (
            <li
              key={zone.id}
              className="flex items-center justify-between rounded-xl border bg-card px-4 py-2 text-sm"
            >
              <span>
                Zone {i + 1} ·{" "}
                {zone.radiusM < 1000 ? `${zone.radiusM} m` : `${zone.radiusM / 1000} km`}
              </span>
              <Button
                size="sm"
                variant="ghost"
                aria-label={`Remove zone ${i + 1}`}
                disabled={remove.isPending}
                onClick={() => remove.mutate(zone.id)}
              >
                <Trash2 /> Remove
              </Button>
            </li>
          ))}
        </ul>
      ) : (
        zones.isSuccess && <p className="text-sm text-muted-foreground">No privacy zones yet.</p>
      )}
    </section>
  );
}

const formatBytes = (bytes: number) =>
  bytes < 1024 * 1024
    ? `${Math.max(1, Math.round(bytes / 1024))} KB`
    : `${(bytes / (1024 * 1024)).toFixed(1)} MB`;

const exportQueryKey = ["me", "export"] as const;

function ExportData() {
  const queryClient = useQueryClient();
  const latest = useQuery({
    queryKey: exportQueryKey,
    queryFn: fetchLatestExport,
    // Poll while it builds; afterwards now and then, which also keeps the session cookies
    // fresh for the plain download links.
    refetchInterval: (query) => {
      const status = query.state.data?.status;
      return status === "queued" || status === "building" ? 2_000 : 5 * 60_000;
    },
  });
  const start = useMutation({
    mutationFn: startExport,
    onSuccess: (job) => queryClient.setQueryData(exportQueryKey, job),
  });
  const job = latest.data ?? null;
  const running = job?.status === "queued" || job?.status === "building";
  const percent =
    job && job.progress.total > 0 ? Math.floor((100 * job.progress.done) / job.progress.total) : 0;
  const limited = start.error instanceof ApiError && start.error.status === 429;
  return (
    <section className="grid gap-3" aria-labelledby="export-data">
      <h2 id="export-data" className="text-lg font-semibold">
        Export your data
      </h2>
      <p className="max-w-prose text-sm text-muted-foreground">
        Get ZIP files with your profile, settings, privacy zones, every session's details and every
        track file as you uploaded it. Track files contain precise locations and times. Preparing a
        large account takes a few minutes; the files are kept for 7 days.
      </p>
      {running ? (
        <p className="text-sm" role="status" aria-live="polite">
          Preparing… {percent}%
        </p>
      ) : (
        <div>
          <Button variant="outline" disabled={start.isPending} onClick={() => start.mutate()}>
            <Download />{" "}
            {start.isPending
              ? "Starting…"
              : job?.status === "failed" || job?.status === "expired"
                ? "Start again"
                : job?.status === "ready"
                  ? "Export again"
                  : "Export all my data"}
          </Button>
        </div>
      )}
      {job?.status === "failed" && (
        <p className="text-sm text-red-600" role="alert">
          The last export could not be finished{job.error ? `: ${job.error}` : "."}
        </p>
      )}
      {job?.status === "expired" && (
        <p className="text-sm text-muted-foreground">The last export's files have expired.</p>
      )}
      {start.isError && (
        <p className="text-sm text-red-600" role="alert">
          {limited
            ? "You have started several exports today. Try again tomorrow."
            : "Could not start the export. Try again."}
        </p>
      )}
      {job?.status === "ready" && job.omitted > 0 && (
        <p className="text-sm text-amber-700 dark:text-amber-400" role="status">
          {job.omitted === 1 ? "1 item couldn't" : `${job.omitted} items couldn't`} be included —
          see errors.json in part 1.
        </p>
      )}
      {job?.status === "ready" && (
        <ol className="grid gap-2" aria-label="Export files">
          {job.parts.map((part) => (
            <li
              key={part.part}
              className="flex flex-wrap items-center justify-between gap-2 rounded-xl border bg-card px-4 py-2 text-sm"
            >
              <span>
                Part {part.part} of {job.parts.length}
                {part.part === 1 ? " (start here: list of all files)" : ""}
                <span className="text-muted-foreground"> · {formatBytes(part.bytes)}</span>
              </span>
              <a
                className={buttonVariants({ size: "sm", variant: "outline" })}
                href={`/api${part.url}`}
                download
              >
                <Download /> Download part {part.part}
              </a>
            </li>
          ))}
        </ol>
      )}
      {job?.status === "ready" && job.expiresAt && (
        <p className="text-xs text-muted-foreground">
          Available until {new Date(job.expiresAt).toLocaleDateString()}.
        </p>
      )}
    </section>
  );
}

function DeleteAccount({ me, onDeleted }: { me: Me; onDeleted: () => void }) {
  const deleteAccount = useDeleteAccount();
  const [confirming, setConfirming] = useState(false);
  // The account shown when the confirmation opened, never whoever is signed in by the time
  // the button is pressed (another tab may have switched accounts).
  const [confirmed, setConfirmed] = useState<Me | null>(null);
  const remove = useMutation({
    mutationFn: () => deleteAccount((confirmed ?? me).id),
    onSuccess: onDeleted,
  });
  const mismatch = remove.error instanceof ApiError && remove.error.status === 409;
  return (
    <section className="grid gap-3 border-t pt-8" aria-labelledby="delete-account">
      <h2 id="delete-account" className="text-lg font-semibold">
        Delete account
      </h2>
      {confirming ? (
        <div
          className="grid max-w-prose gap-3 rounded-xl border border-red-600/40 bg-red-600/5 p-4 text-sm"
          role="alertdialog"
          aria-labelledby="delete-account-confirm"
          aria-describedby="delete-account-details"
        >
          <p id="delete-account-confirm" className="flex items-center gap-2 font-medium">
            <TriangleAlert className="size-4 text-red-600" aria-hidden /> Delete the MadeGood
            account @{(confirmed ?? me).handle}?
          </p>
          <p id="delete-account-details" className="text-muted-foreground">
            This deletes every session you have uploaded, your privacy zones, your settings and your
            sign-in from MadeGood's servers. Sessions recorded on your iPhone and Apple Watch stay
            on those devices, and workouts in Apple Health are not affected. This can't be undone.
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              className="bg-red-600 text-white hover:bg-red-600/90"
              disabled={remove.isPending}
              onClick={() => remove.mutate()}
            >
              {remove.isPending ? "Deleting…" : "Delete my account"}
            </Button>
            <Button
              variant="outline"
              disabled={remove.isPending}
              onClick={() => {
                remove.reset();
                setConfirming(false);
                setConfirmed(null);
              }}
              autoFocus
            >
              Cancel
            </Button>
          </div>
          {remove.isError && (
            <p className="text-red-600" role="alert">
              {mismatch
                ? "You are now signed in to a different account. Reload the page and check which account to delete."
                : "Could not delete the account. Try again."}
            </p>
          )}
        </div>
      ) : (
        <>
          <p className="max-w-prose text-sm text-muted-foreground">
            Permanently delete your account and everything uploaded to it. Recordings on your
            devices are kept.
          </p>
          <div>
            <Button
              variant="outline"
              className="text-red-600"
              onClick={() => {
                setConfirmed(me);
                setConfirming(true);
              }}
            >
              <Trash2 /> Delete account…
            </Button>
          </div>
        </>
      )}
    </section>
  );
}
