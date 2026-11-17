export type Health = {
  status: "ok" | "degraded";
  version: string;
  db: "ok" | "error";
};

export async function fetchHealth(): Promise<Health> {
  const response = await fetch("/api/health");
  if (!response.ok && response.status !== 503)
    throw new Error(`Health check failed: ${response.status}`);
  return response.json();
}
