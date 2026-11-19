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
- Each sign-in's window is written to `consent.json` before its credentials reach the
  Keychain, and closed before a sign-out removes them (`ConsentRecordingStore`). A failed
  consent write fails the sign-in; credentials without a recorded window get nothing
  automatically.
- A recording uploads automatically only when its whole time range, widened by 10 min on
  each side for clock skew, lies inside one window of this account. A recording that
  touches an account switch or a time nobody was signed in appears under **Upload N
  Earlier Sessions**. One whose widened range touches another account's window is only
  ever offered to the account signed in when it started (explicitly), never to another.
- Sign-out cancels that sign-in's uploads and deletes its queue and frozen tracks.
- A session the user deleted from the account (the server answers 410) is recorded and
  never queued for that account again.

## Queue

`App/Sources/SessionSync/Core/SessionOutbox.swift` keeps a JSON journal per sign-in under
Application Support (excluded from backup). Each finished recording is analyzed once, with
its local trim applied, and frozen: the metadata for `PUT /sessions/{id}` and a copy of the
gzipped track v1 for `PUT /sessions/{id}/track`. Retries resend the same bytes. A recording
whose trim can't be read waits rather than uploading the untrimmed track.

Each snapshot records what it was made from (the trim and the analysis inputs), a
generation, and an upload revision that increases with every new snapshot. When any input
changes, synced or not, the session is frozen again (into a new per-generation file; the
journal is committed before the old file is removed) and starts over with metadata. A
request still carrying the old snapshot is cancelled and its result ignored, and the
server rejects both PUTs for a lower revision than it stores (412, with the stored
revision in `Upload-Revision`; the phone then continues above it, within the attempt
limit). Metadata updates are compare-and-swap on the revision read: the same revision
never detaches the track, and older track objects are found from the bucket listing and
deleted after each successful PUT, so a failed delete is retried. The server keeps each
revision's track as its own object and detaching the old track as soon as newer metadata
arrives. So trimmed-off data never stays on, or returns to, the account.

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
  signed out, another sign-in, a different Wi-Fi setting, or not the journal's current
  generation) are cancelled. A track upload that
  finishes while nothing waits for it is journalled from the delegate, so it is not resent.
- 401: one refresh and retry; a failed refresh signs out.
- 409 (**Belongs to another account**), 410 (**Deleted from your account**), 413 or a track
  over 8 MiB (**Too large to upload**) and other 4xx (**Upload rejected**) stop without
  retrying. A 404 or 412 on the track resends the metadata first.
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
