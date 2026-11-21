import { sessionHint } from "./session-cookie";

// The website talks to the same API as the apps. It authenticates with HttpOnly cookies
// set by /api/auth/web/*, which page scripts never see; on a 401 it rotates them once
// through /api/auth/web/refresh and retries.

export type Health = {
  status: "ok" | "degraded";
  version: string;
  db: "ok" | "error";
};

export type Units = "metric" | "imperial" | "nautical";
export type Visibility = "private" | "unlisted" | "public";
export type Sport = "sailing" | "windsurfing" | "motorboating" | "kayak" | "canoe" | "sup";

export type Me = {
  id: string;
  handle: string;
  displayName: string | null;
  publicProfileKey: string | null;
  publicProfileUsername: string | null;
  publicProfileDisplayName: string | null;
  units: Units;
  defaultVisibility: Visibility;
  createdAt: string;
};

export type Session = {
  id: string;
  sport: Sport;
  title: string | null;
  notes: string | null;
  visibility: Visibility;
  owner: { profileKey: string; displayName: string | null } | null;
  startedAt: string;
  endedAt: string | null;
  durationS: number | null;
  movingS: number | null;
  distanceM: number | null;
  maxSpeedMps: number | null;
  avgSpeedMps: number | null;
  summary: Record<string, unknown> | null;
  analyzerVersion: string | null;
  hasTrack: boolean;
  /** Server post-processing of the track (docs/self-hosting.md). */
  processing: "none" | "pending" | "done" | "too_large" | "invalid";
  /** The owner's whole track, or for others only what the shared track shows. */
  bounds: { south: number; west: number; north: number; east: number } | null;
  trackStartedAt: string | null;
  trackEndedAt: string | null;
  /** Modelled wind, for public and unlisted sessions only. */
  wind: {
    source: "weatherkit";
    directionDeg: number | null;
    speedMps: number | null;
    gustMps: number | null;
    samples: {
      t: string;
      directionDeg: number | null;
      speedMps: number | null;
      gustMps: number | null;
    }[];
    fetchedAt: string;
  } | null;
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
};

export type SessionList = { sessions: Session[]; nextCursor: string | null };

type Totals = { sessions: number; distanceM: number; movingS: number; durationS: number };
export type MeStats = Totals & { bySport: (Totals & { sport: Sport })[] };

/** A public session as a profile lists it (GET /api/users/:profileKey). */
export type PublicSessionSummary = Pick<
  Session,
  | "id"
  | "sport"
  | "title"
  | "startedAt"
  | "durationS"
  | "movingS"
  | "distanceM"
  | "maxSpeedMps"
  | "avgSpeedMps"
>;

/** A user's public profile: totals and sessions cover public sessions only. */
export type PublicProfile = {
  displayName: string | null;
  isOwner: boolean;
  totals: MeStats;
  sessions: PublicSessionSummary[];
  nextCursor: string | null;
};

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string | undefined,
    message: string,
  ) {
    super(message);
  }
}

let refreshing: Promise<boolean> | null = null;

const hint = () => sessionHint(document.cookie, Date.now());

async function postRefresh(): Promise<boolean> {
  const response = await fetch("/api/auth/web/refresh", {
    method: "POST",
    credentials: "same-origin",
  });
  return response.ok;
}

/**
 * Rotates the session cookies. Calls in this tab share one request; across tabs a Web
 * Lock serializes them, and a tab that waited skips its own refresh when another tab
 * already renewed the cookies (`force` skips that check after a 401). The server also
 * tolerates a refresh token replayed within 30 s, for browsers without Web Locks.
 */
function refreshSession(force = false): Promise<boolean> {
  refreshing ??= (async () => {
    const run = async () => (!force && hint() === "fresh" ? true : postRefresh());
    try {
      return navigator.locks ? await navigator.locks.request("madegood-refresh", run) : await run();
    } catch {
      return false;
    }
  })().finally(() => {
    refreshing = null;
  });
  return refreshing;
}

/**
 * fetch() for /api paths with the session cookies. It waits for a refresh in flight,
 * refreshes first when the access cookie is about to lapse (so a signed-in request never
 * goes out anonymous and gets a 404 for a private session), and refreshes and retries
 * once on 401.
 */
export async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  if (refreshing) await refreshing;
  if (hint() === "stale") await refreshSession();
  const request = () => fetch(`/api${path}`, { ...init, credentials: "same-origin" });
  const response = await request();
  if (response.status !== 401 || hint() === "none") return response;
  // A failed refresh clears the cookies, so the retry is anonymous: public pages still load.
  await refreshSession(true);
  return request();
}

async function failure(response: Response): Promise<ApiError> {
  const body = (await response.json().catch(() => ({}))) as { error?: string; message?: string };
  return new ApiError(
    response.status,
    body.error,
    body.message ?? `Request failed: ${response.status}`,
  );
}

export async function apiJson<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await apiFetch(path, init);
  if (!response.ok) throw await failure(response);
  return response.json() as Promise<T>;
}

const jsonInit = (method: string, body: unknown): RequestInit => ({
  method,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

export async function fetchHealth(): Promise<Health> {
  const response = await fetch("/api/health");
  if (!response.ok && response.status !== 503)
    throw new Error(`Health check failed: ${response.status}`);
  return response.json();
}

export type DownloadLink = { url: string; store: "testflight" | "app-store" };

export async function fetchSiteConfig(): Promise<{ download: DownloadLink | null }> {
  const response = await fetch("/api/config");
  if (!response.ok) throw await failure(response);
  return response.json();
}

/** Whether this browser expects a web session (the server's script-readable `mg_web` hint). */
export const hasWebSession = () => hint() !== "none";

/** The signed-in user, or null when signed out. */
export async function fetchMe(): Promise<Me | null> {
  if (!hasWebSession()) return null;
  const response = await apiFetch("/me");
  if (response.status === 401) return null;
  if (!response.ok) throw await failure(response);
  return response.json();
}

export const fetchStats = () => apiJson<MeStats>("/me/stats");

export const fetchSessions = (cursor: string | null) =>
  apiJson<SessionList>(
    `/sessions?limit=20${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
  );

export const fetchProfile = (profileKey: string, cursor: string | null) =>
  apiJson<PublicProfile>(
    `/users/${encodeURIComponent(profileKey)}?limit=20${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`,
  );

export const fetchSession = (id: string) => apiJson<Session>(`/sessions/${encodeURIComponent(id)}`);

export const updateSession = (
  id: string,
  changes: Partial<Pick<Session, "title" | "notes" | "visibility">>,
) => apiJson<Session>(`/sessions/${encodeURIComponent(id)}`, jsonInit("PATCH", changes));

export async function signOut(): Promise<void> {
  // Let a refresh in flight land first, so it cannot restore the cookies afterwards. The
  // server ends the whole sign-in either way (finding 1 of the #63 review).
  if (refreshing) await refreshing.catch(() => false);
  await fetch("/api/auth/web/signout", { method: "POST", credentials: "same-origin" });
}

/**
 * Deletes the account shown to the user, and everything uploaded to it (DELETE /api/me). The
 * server clears the session cookies in the same response. Sessions on the user's devices are not touched.
 */
export async function deleteAccount(userId: string): Promise<void> {
  // The server refuses (409) unless `userId` is the signed-in account, so a confirmation
  // left open while another account signed in can never delete that one.
  const response = await apiFetch("/me", jsonInit("DELETE", { userId }));
  if (!response.ok) throw await failure(response);
}

export type AccountExport = {
  id: string;
  status: "queued" | "building" | "ready" | "failed" | "expired";
  createdAt: string;
  expiresAt: string | null;
  progress: { done: number; total: number };
  /** Set once ready; `url` is a path under /api. */
  parts: { part: number; bytes: number; url: string }[];
  /** Files left out of a ready export; errors.json in part 1 lists them. */
  omitted: number;
  error: string | null;
};

/** The newest export, if any (GET /api/me/exports). */
export const fetchLatestExport = () =>
  apiJson<{ exports: AccountExport[] }>("/me/exports").then((r) => r.exports[0] ?? null);

/** Starts an export (POST /api/me/exports); a running one is returned instead (409). */
export async function startExport(): Promise<AccountExport> {
  const response = await apiFetch("/me/exports", { method: "POST" });
  if (response.status === 409) {
    const body = (await response.json()) as { message?: string };
    if (body.message)
      return apiJson<AccountExport>(`/me/exports/${encodeURIComponent(body.message)}`);
  }
  if (!response.ok) throw await failure(response);
  return response.json() as Promise<AccountExport>;
}

/** Full-page navigation to Apple's sign-in, returning to `next` afterwards. */
export const signInUrl = (next: string) => `/api/auth/web/apple?next=${encodeURIComponent(next)}`;

export type PrivacyZone = { id: string; lat: number; lon: number; radiusM: number };

export const fetchZones = () =>
  apiJson<{ zones: PrivacyZone[] }>("/me/privacy-zones").then((r) => r.zones);

export const addZone = (zone: Omit<PrivacyZone, "id">) =>
  apiJson<PrivacyZone>("/me/privacy-zones", jsonInit("POST", zone));

export async function deleteZone(id: string): Promise<void> {
  const response = await apiFetch(`/me/privacy-zones/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
  if (!response.ok) throw await failure(response);
}

export const updateMe = (
  userId: string,
  changes: Partial<
    Pick<Me, "units" | "defaultVisibility" | "publicProfileDisplayName" | "publicProfileUsername">
  > & {
    publicProfileEnabled?: boolean;
  },
) => apiJson<Me>("/me", jsonInit("PATCH", { userId, ...changes }));
