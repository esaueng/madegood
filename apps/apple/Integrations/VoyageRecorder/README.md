# Private sync for a saved voyage leg

Open a completed leg in Voyages. After signing in under Settings, choose
**Sync Leg Privately** and confirm. The confirmation uses the sign-in that was
active when the prompt opened. Finishing or resuming a leg keeps it on the phone.
The outbox queues the voyage, then the leg, then a file-backed upload of the
original gzip bytes. Sign-out cancels pending work for that sign-in. A new
sign-in requires a new decision, including for the same account. Private sync
uses the owner's voyage routes and is independent of live sharing.

The voyage start is the first recorded leg's start. The recorder supplies
neither a whole-voyage end nor boat, port or distance metadata. Track v1
preserves the leg UUID, start and relative fix times at millisecond precision.
A `recording_gap` event starts at `t` and carries the gap end in `data.endT`, also
in seconds since leg start. This includes gaps before a saved fix and an ending
gap. The local voyage index and position journal remain the recorder's source
of truth.

## Swift client generation

The Swift client is generated from the [Worker contract](../../../../openapi/openapi.json)
with Apple Swift OpenAPI Generator 1.10.4.

Run the generator from the repository root with the pinned version on your path.

```sh
swift-openapi-generator generate openapi/openapi.json \
  --config apps/apple/Integrations/VoyageRecorder/swift-voyage-generator.yaml \
  --output-directory apps/apple/App/Sources/PrivateVoyageSync/Core/Generated
```

The same generated sources compile in Tuist and SwiftPM. The transport bridge
adds the current bearer token, preserves the HTTP status and retry delay, and
routes track uploads through the existing background URLSession using the
outbox file.

## Local verification

Run `swift test --package-path packages/WaterKit` and
`swift test --package-path apps/apple`. The private sync suite uses a synthetic
account and transport. It covers restored recording continuity, request
order, snapshot and track times, stable gzip retries, conflicts, refresh
rotation, sign-out and preservation of the recorder files.

The Debug-only `-demoPrivateVoyageSync` option uses a synthetic sign-in,
temporary outbox and in-process test transport. The iPhone UI tests use synthetic
Core Location fixes and exercise the saved-leg action with that account. A
signed physical-device build needs Sign in with Apple provisioning and an API
configured for its audience. Real Apple sign-in, device Keychain behavior,
background session relaunch and overnight location capture require separate
device verification. Sign-out does not undo requests the server has already
accepted.
