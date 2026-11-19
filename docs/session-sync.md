# iPhone session sync

The iPhone uploads finished sessions to the signed-in MadeGood account (PLAN.md §4.1,
Phase 3 task 3). The watch never calls the API; its sessions sync once they reach the phone.

## Turning it on

1. The build needs an API root: set `MADEGOOD_API_URL` in `apps/apple/Config/Local.xcconfig`
   (see `Local.xcconfig.example`). Without it, Settings > Account says sync isn't set up.
2. Settings > Account: Sign in with Apple. The identity token goes to `POST /auth/apple`;
   the token pair is kept in the Keychain (this device only) and refreshed on a 401 with
   the rotating refresh token, as in private Voyage sync.
3. Turn on **Sync sessions**. Nothing uploads before both steps. **Upload on Wi-Fi only**
   keeps uploads off cellular and other expensive networks.

Uploaded sessions take the account's default visibility, which starts private.

## Consent (`SessionSyncConsent`)

Sync never sends a recording to an account that did not consent to it.

- The switch is on only for the sign-in that turned it on. Signing out, losing the
  sign-in (a failed refresh) or signing in again, even to the same account, turns it off.
- A recording started while an account was signed in belongs to that account and uploads
  to it automatically. A recording started while another account was signed in never
  uploads to this one.
- Recordings made while nobody was signed in upload only after **Upload N Earlier
  Sessions** in Settings.
- Sign-out cancels that sign-in's uploads and deletes its queue and frozen tracks.

## Queue

`App/Sources/SessionSync/Core/SessionOutbox.swift` keeps a JSON journal per sign-in under
Application Support (excluded from backup). Each finished recording is analyzed once, with
its local trim applied, and frozen: the metadata for `PUT /sessions/{id}` and a copy of the
gzipped track v1 for `PUT /sessions/{id}/track`. Retries resend the same bytes. A recording
whose trim can't be read waits rather than uploading the untrimmed track.

Each snapshot records what it was made from (the trim and the analysis inputs). When a
queued session's trim or inputs change before it synced, it is frozen again and starts
over with metadata; a request still carrying the old snapshot is cancelled and its result
ignored (each snapshot has a generation in its task description). When the trim of a
synced session changes, it uploads again: both PUTs replace what the account stored, so
trimmed-off data is removed. Other changes after a session synced (for example the
auto-pause setting) are not uploaded again.

- Order: metadata, then the track, through a background URLSession (`.session-track`), so a
  track upload continues while the app is suspended.
- Session IDs are device UUIDs, so both PUTs are idempotent.
- Transient failures (5xx, 408, 425, 429, other transport errors) back off 10 s, 20 s, …
  up to 1 h, honoring `Retry-After`, and stop after 8 attempts as **Upload failed**.
- Offline waits without using attempts and resumes when the network returns. Connection
  errors (DNS, refused) count as offline only when NWPathMonitor reports no usable path
  for the Wi-Fi setting; on a working network they use up attempts like other failures.
- The background session and its delegate are created at launch, including a background
  relaunch. Before anything else, uploads the current settings no longer allow (sync off,
  signed out, another sign-in, a different Wi-Fi setting) are cancelled. A track upload that
  finishes while nothing waits for it is journalled from the delegate, so it is not resent.
- 401: one refresh and retry; a failed refresh signs out.
- 409 (**Belongs to another account**), 413 or a track over 8 MiB (**Too large to upload**)
  and other 4xx (**Upload rejected**) stop without retrying. A 404 on the track resends the
  metadata first.
- Retry (session detail, or Settings for all) clears the failure and backoff.
- Deleting a recording drops it from the queue unless it is already synced. Sign-out
  cancels that sign-in's uploads and removes its queue.

History rows and session detail show the status while sync is on.

## Tests

`swift test --package-path apps/apple` runs the queue tests with an in-memory transport.
`PhoneSessionSyncUITests` launches with `-demoSessionSync`: a synthetic account and an
in-process server; no network.

## Not covered yet

- Real Sign in with Apple, Keychain and background relaunch need a signed device build.
