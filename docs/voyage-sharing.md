# Voyage sharing policy

The server library in `web/src/server/lib/voyage-sharing.ts` projects a viewer state from
synthetic or privately synced voyage data. The Voyage recorder and private sync own the
original fixes, recording breaks, and metadata. The sharing adapter supplies the voyage ID,
the capture timestamp in epoch milliseconds, the immutable server time of first receipt,
and an internal segment ID that changes at a recording break or leg boundary.

- Sharing starts off for every voyage. An explicit owner action issues a random link with a
  finite exclusive expiry. Store its hash and generation. Rotation starts a new generation
  and a new capture window. The owner sees off, on, or paused, the configured delay, and a
  preview from the same projection used for recipients.
- The delay acts on capture time. A fix can enter history when its capture reaches the
  delayed cutoff. The current fix must be younger than the freshness window relative to
  that cutoff. First receipt prevents fixes dated in the future from aging into view.
  It never makes backfill look live.
- With an eligible current fix, the projection includes only coordinates and capture times
  that pass the owner's privacy zones. Hidden fixes, conflicting samples, recording breaks,
  and possible zone crossings split the track. The spherical segment test is conservative
  and can split near misses. Render each segment independently along shortest great-circle
  arcs. A map that cannot honor that geometry can render individual points.
- A private, invalid, expired, revoked or paused share, an unavailable privacy configuration,
  and a missing, stale or hidden current fix all return `{ "status": "unavailable" }`.
  That state clears the entire projection. Available projections carry only the current fix
  and filtered track segments. Keep the viewer page and link preview generic and keep
  voyage names, boat names, port names, logs, routes, bounds and other private metadata
  outside the viewer response.

## Transport handoff

The [local transport prototype](local-voyage-transport.md) implements this handoff for synthetic
tracks. The production dependencies are listed with the local demo.

1. Map private sync to the snapshot inputs above. Preserve the first server receipt across
   retries and retain hidden fixes and segment breaks in the private input. Obtain the
   owner's full privacy settings server-side. Treat a failed lookup as unavailable.
2. Add an authenticated owner control for issue, pause, revoke, and rotate. Persist share
   changes atomically for the voyage and serialize concurrent writes. Keep the generation
   across revoke, expiry, and reissue. Pause holds the viewer projection while the link
   remains valid. Revoke and reissue to start a new capture window when the owner wants to
   keep the intervening recording private.
3. Use the per-voyage Durable Object as the serialization point for the current share,
   viewer projection, and sends. Use a slug lookup to locate the object, then authorize
   the link against its authoritative share on every connection and reconnect. Bind each
   active connection to its server-side grant. Recheck the latest policy and grant after any
   asynchronous work and before every send. On revoke, rotation, expiry, or voyage deletion,
   clear the view and close affected connections as part of the state change. Schedule expiry,
   freshness and delay transitions even when no batch arrives. On pause, privacy edits, or
   backfill, send a full replacement projection. The viewer clears its state on unavailable
   or disconnect and reloads from the latest projection on reconnect. Use generic metadata
   and uncached responses so a separate presentation path cannot retain a private fix.
4. Run a local Worker and Durable Object test with two synthetic voyages, a connected
   viewer, and a reconnecting viewer. Use a controlled clock to check delay, stale/offline
   transitions, and exact expiry without ingest. Post scrambled, duplicate and future
   fixes and verify history order, segment breaks, privacy-zone entry/exit and payload
   parity on reconnect. While sends are pending, pause, revoke and rotate; verify the
   preview clears, superseded connections close, and old links cannot reconnect. Inspect
   viewer HTML, link metadata and socket frames for private fields.

The policy acceptance tests run with `pnpm -C web test test/voyage-sharing.test.ts`.
