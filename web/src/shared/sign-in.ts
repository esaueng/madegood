/** A same-site return path. Sign-in links from profile pages go to the dashboard. */
export function safeNext(value: string | undefined | null): string {
  if (!value?.startsWith("/") || value.startsWith("//") || value.includes("\\")) {
    return "/sessions";
  }
  const pathname = value.split(/[?#]/, 1)[0]?.toLowerCase();
  if (pathname === "/u" || pathname?.startsWith("/u/")) return "/sessions";
  return value.length > 512 ? "/sessions" : value;
}

export const signInUrl = (next: string) =>
  `/api/auth/web/apple?next=${encodeURIComponent(safeNext(next))}`;
