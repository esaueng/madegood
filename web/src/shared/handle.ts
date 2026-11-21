/** Handles are lowercase, 3–30 of a–z, 0–9 and `_`, and appear in URLs (`/u/<handle>`). */
export const HANDLE_PATTERN = /^[a-z0-9_]{3,30}$/;

export const normalizeHandle = (handle: string) => handle.trim().toLowerCase();
