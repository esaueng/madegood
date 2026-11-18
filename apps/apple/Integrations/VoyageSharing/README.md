# iPhone live voyage sharing

The controls run in a Debug iPhone simulator launched with
`-localVoyageSharing` and a synthetic account on a Wrangler Worker bound to
`127.0.0.1`. The launch environment supplies the Worker port
(`MADEGOOD_TEST_WORKER_PORT`), synthetic account ID
(`MADEGOOD_TEST_VOYAGE_ACCOUNT`), synthetic access token
(`MADEGOOD_TEST_VOYAGE_TOKEN`) and a fresh UUID (`MADEGOOD_TEST_VOYAGES`).
The test credential store is in memory. A launch with incomplete loopback
configuration falls back to the in-process private sync demo.

Live sharing requires confirmation in a voyage with at least one leg. The
owner chooses the position delay and link duration. The owner preview uses
the Worker projection, including unavailable states and segment boundaries.
Stop immediately discards the queue and preview. Wait for the Worker to
acknowledge revoke before treating the link as disabled. If Stop fails while
offline, reopen the voyage and retry it when connected.

Each outbox belongs to one sign-in and server grant generation. The recorder
feeds only newly committed fixes and preserves the original capture time.
A leg boundary, recording gap or restore creates a new segment for the next
fix. Batches carry the outbox's generation and preserve each sample UUID
through retries. The authoritative Durable Object validates the generation
inside its receipt transaction. A changed or expired grant discards the
queue. Journals from before generation binding are discarded. The phone
drains while the voyage detail is visible and the app is active.

The server can pause a grant and resume the same capture window. The phone
discards its queue when it observes a pause. Revoke and reissue to start a new
window. Completed-leg private sync continues through its independent outbox.

Both phone flows use the [shared Swift API adapter](../VoyageRecorder/README.md)
generated from the repository's OpenAPI document. Run the synthetic phone
flow with `scripts/test-voyage-sharing` after building the Apple Swift package.
To exercise the Debug iPhone app and actual Worker together, run
`PhoneVoyageLoopbackUITests` with the test-runner environment above and an
additional synthetic outsider token in `MADEGOOD_TEST_VOYAGE_OUTSIDER`.
The test supplies its own run UUID to the app. Use an ad-hoc signed Debug
simulator build (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so
`nsurlsessiond` can accept the file-backed private track upload. See the
[local Worker setup](../../../../docs/local-voyage-transport.md).
