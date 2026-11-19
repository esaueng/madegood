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
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
};

export type SessionList = { sessions: Session[]; nextCursor: string | null };

type Totals = { sessions: number; distanceM: number; movingS: number; durationS: number };
export type MeStats = Totals & { bySport: (Totals & { sport: Sport })[] };

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

/** Rotates the session cookies; concurrent callers share one request. */
function refreshSession(): Promise<boolean> {
  refreshing ??= fetch("/api/auth/web/refresh", { method: "POST", credentials: "same-origin" })
    .then((response) => response.ok)
    .catch(() => false)
    .finally(() => {
      refreshing = null;
    });
  return refreshing;
}

/** fetch() for /api paths: same-origin cookies, one refresh-and-retry on 401. */
export async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const request = () => fetch(`/api${path}`, { ...init, credentials: "same-origin" });
  const response = await request();
  if (response.status !== 401 || !hasWebSession()) return response;
  // A failed refresh clears the cookies, so the retry is anonymous: public pages still load.
  await refreshSession();
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

/** Whether this browser has a web session (the server's script-readable `mg_web` hint). */
export const hasWebSession = () => /(?:^|;\s*)mg_web=1(?:;|$)/.test(document.cookie);

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

export const fetchSession = (id: string) => apiJson<Session>(`/sessions/${encodeURIComponent(id)}`);

export const updateSession = (
  id: string,
  changes: Partial<Pick<Session, "title" | "notes" | "visibility">>,
) => apiJson<Session>(`/sessions/${encodeURIComponent(id)}`, jsonInit("PATCH", changes));

export async function signOut(): Promise<void> {
  await fetch("/api/auth/web/signout", { method: "POST", credentials: "same-origin" });
}

/** Full-page navigation to Apple's sign-in, returning to `next` afterwards. */
export const signInUrl = (next: string) => `/api/auth/web/apple?next=${encodeURIComponent(next)}`;
