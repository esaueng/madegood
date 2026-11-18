# Private voyage sync

The Worker slice stores voyage and completed leg snapshots for the signed-in account. It uses the existing MadeGood bearer tokens. Private sync and opt-in live sharing are independent. Enabling private sync keeps records and tracks visible only to the owner.

Private Voyage routes are disabled by default. The local synthetic test harness sets `VOYAGE_PRIVATE_LOCAL=1`. The default iPhone launch keeps all Voyage recordings local. The Debug-only `-demoPrivateVoyageSync` launch option exercises consent and upload through a synthetic account and transport.

## API and storage contract

Use the generated [OpenAPI document](../openapi/openapi.json) for operation names and request and response types. The paths below are relative to `/api`.

| Resource | Paths | Behavior |
|---|---|---|
| Voyage | `GET /voyages`, `GET /voyages/{voyageId}`, `PUT /voyages/{voyageId}` | List, read, and create a private metadata snapshot. |
| Leg | `GET /voyages/{voyageId}/legs`, `GET /voyages/{voyageId}/legs/{legId}`, `PUT /voyages/{voyageId}/legs/{legId}` | List, read, and create a completed leg under an existing voyage. |
| Leg track | `GET` and `PUT /voyages/{voyageId}/legs/{legId}/track` | Download or upload one private gzip track v1 file for the leg. |

- Generate a UUID on the phone for each voyage and leg and persist it at creation. The API accepts either case and returns lowercase IDs. D1 keys include the authenticated account ID. Two accounts can use the same device IDs without observing or modifying each other's records. A missing resource and a resource owned by another account both return `404 not_found`. Requests with invalid credentials or a deleted account return `401 unauthorized` at entry.
- Metadata creates return `201`. Retrying the same normalized fields returns `200`. The API trims names, treats omitted and blank optional names as null, and compares timestamps at millisecond precision. A leg requires start and end dates in order. Distances are metres. Different content for the same ID in the same account, including a different parent for a leg, returns `409 sync_conflict`. Record edits, individual deletes and incremental change feeds need a separate revision contract.
- Lists return up to 100 records in UUID order. Follow `nextCursor` until null. Start a fresh scan for later reconciliation because a concurrently inserted UUID can sort before the current cursor. Sort by dates locally for presentation.
- Send the original WaterKit track v1 gzip bytes as `application/gzip`, with no `Content-Encoding`. Use the leg UUID for the track's `sessionId`. The API validates the complete track before writing it, including the version, leg ID, sample columns and event structure. Private leg tracks are limited to 8 MiB compressed and 16 MiB inflated. First upload and byte-identical retries return `204`. Different bytes return `409 sync_conflict`. R2 keys are internal and include the account, voyage and leg IDs.
- `DELETE /me` cascades D1 voyage and leg rows and sweeps the account's R2 prefix. An upload checks the leg before and after writing R2 and removes a late object if deletion won the race. Reads check ownership before serving the track. Repeat account deletion with the same still-valid access token to retry prefix cleanup after a storage error. If a Worker is interrupted after writing a late object and before cleanup, it can remain in R2 under the deleted account's prefix. A durable cleanup mechanism is a follow-on before production rollout.

## Integration with future viewer projection

Keep authenticated ownership, accepted capture timestamps, and first server receipt separate. This slice preserves accepted voyage and leg times at millisecond precision and retains the original track bytes, including relative sample times and recorded events. The create-only R2 write preserves the original object's server receipt on retries. A later position ingest contract must persist its own immutable first server receipt when each capture is first accepted.

Each leg has a separate ID and track. The recording workstream should preserve explicit leg and recording breaks in the private input. Viewer projection will need the full private input and authoritative server privacy state to determine what it can return. Public grants, transport and viewer projection belong to separate workstreams.

## iPhone implementation handoff

1. Add Sign in with Apple using AuthenticationServices and exchange `identityToken` via `POST /auth/apple`. Store the returned MadeGood `user.id` and token pair in Keychain. Serialize refresh through a single task and save the rotated pair before releasing waiting API requests. Reusing a rotating refresh token revokes that account's refresh tokens. If a refresh result is lost and the new token cannot be recovered, return to sign-in. Regenerate the Swift API client from OpenAPI and add bearer auth for private calls.
2. Have the voyage storage workstream persist IDs, parent ID, frozen upload metadata, and the leg's original track v1 file URL in the local repository. Use a voyage-specific library so the existing Sessions and watch transfer entry points keep their current behavior. The local storage and recording workstreams own models, file paths, and track generation.
3. Persist the outbox with the MadeGood account ID and the local snapshots or a recoverable reference to each. Keep a stable upload file so a retry uses the same bytes, even after analysis or a restart. Upload voyage metadata, then leg metadata, then the leg track. Use file-backed background URLSession uploads and record acknowledgements per step. On sign-out or account deletion, cancel the account's work and prevent its queued requests from running under a later sign-in, even if it uses the same Apple subject. An explicit user decision is needed to adopt any existing local-only records into another account.
4. Show **On iPhone** for a local-only leg, **Waiting for connection** for queued offline work, **Syncing** during transfers, **Synced** after every required step is acknowledged, and **Retryable failure** for transient failures. Retry transport failures and temporary server errors with backoff. A failed upload leaves the local leg intact. Surface validation and conflict responses for reconciliation. Keep the original IDs across retries and keep the device copy through failed HTTP requests.
