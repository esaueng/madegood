# Local Voyage transport

The acceptance suite exercises the real Worker, local D1 and R2 bindings, and a SQLite-backed Durable Object per account and voyage. It generates synthetic accounts, credentials and tracks. Private completed metadata and track uploads retain their existing routes and storage.

```sh
pnpm install --frozen-lockfile
pnpm -C web test test/voyage-live.test.ts test/voyage-sharing.test.ts test/voyages.test.ts
```

## Contracts

- The owner creates an active private voyage with `PUT /api/voyages/{voyageId}` using a MadeGood access token. Live commands require the same authenticated account and an active voyage. Two accounts can reuse the same voyage UUID without sharing state.
- `POST /api/voyages/{voyageId}/positions` accepts 1–250 fixes. Normalize UUIDs to lowercase. The phone outbox persists a `sampleId` per recorded point and includes its authorizing `grantGeneration` in every batch. Use the original capture time from `VoyageStore.track(for:)` in epoch milliseconds. Allocate a new `segmentId` after every `gapBefore` and at every leg boundary. Store that UUID with the samples it covers so the same boundaries survive backfill, retries and relaunch.
- The object checks the expected generation, revocation and expiry in the same transaction that accepts samples. A stale grant returns `409 stale_grant`. Identical samples within that generation return the original `receivedAtMs` even when a retry is repacked or reordered. That receipt records when the first accepted batch reached the Durable Object. Reusing a sample ID with different content returns `409 sync_conflict` for the batch. Samples captured after first receipt stay private on every retry. The local object accepts up to 10,000 unique fixes per grant and still acknowledges known IDs at capacity. A replacement or revocation discards the previous grant’s live fixes.
- `GET /api/voyages/{voyageId}/sharing` returns the authenticated owner’s controls and filtered preview, with `grantGeneration` for the current valid grant. `POST` accepts `issue`, `rotate`, `pause`, `resume`, `revoke` and `delay`. Issue and rotate accept `delayS` (0–86,400) and `expiresInS` (1–604,800). They return the random slug once. The private capture window starts strictly after the issuance millisecond. Pause holds the window, so resuming can release fixes captured while paused. Revoke and reissue to exclude them. Rotate an active grant if the issuance response was lost.
- `GET /api/live/{slug}` returns a whole snapshot or upgrades to a WebSocket. Viewers replace their state on each frame and clear on disconnect. `/v/{slug}` serves generic metadata and lists points in separate segments. Its initial HTML contains no projection. A share needs a current visible fix less than 600 seconds old relative to the delayed cutoff. Missing privacy data, a hidden current fix, a stale fix and an invalid grant all produce the same unavailable projection.
- D1 stores the hashed locator and identifies the live objects to purge. The object's grant is authoritative. It reads account ownership and privacy zones from D1 for projection, then rechecks its persisted settings and the socket grant synchronously before serialization. It schedules the earliest pending capture, freshness or expiry transition and rechecks D1 every five seconds while a viewer is connected. External privacy edits are observed on the next read or poll. The local acceptance suite controls the clock, forces stored alarms and evicts the object while a viewer is connected. [Cloudflare WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/) · [Cloudflare Alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)

## Manual loopback demo

Use a fresh local checkout and synthetic binding values. Create `web/.dev.vars` with the following local-only values.

```dotenv
VOYAGE_LIVE_LOCAL=1
VOYAGE_PRIVATE_LOCAL=1
JWT_SIGNING_KEY=synthetic-local-signing-key-only-0123456789
```

Apply local migrations, seed an account, and start the loopback Worker from the repository root.

```sh
pnpm -C web db:migrate:local
pnpm -C web exec wrangler d1 execute DB --local --command \
  "INSERT OR IGNORE INTO users (id, apple_sub, handle) VALUES ('synthetic-skipper', 'synthetic-skipper', 'local_skipper'), ('synthetic-outsider', 'synthetic-outsider', 'local_outsider')"
pnpm -C web build
(
  cd web
  pnpm exec wrangler dev --local --config dist/madegood/wrangler.json \
    --env-file "$PWD/.dev.vars" --persist-to "$PWD/.wrangler/state" \
    --ip 127.0.0.1 --port 5173
)
```

In another shell at the repo root, issue synthetic access tokens against the local key and register a refresh token for the skipper.

```sh
access_token_for() {
  (
    cd web
    SYNTHETIC_SUBJECT="$1" node --env-file=.dev.vars --input-type=module -e '
      import { SignJWT } from "jose";
      console.log(await new SignJWT({}).setProtectedHeader({ alg: "HS256", typ: "at+jwt" })
        .setIssuer("madegood").setAudience("madegood-api").setSubject(process.env.SYNTHETIC_SUBJECT)
        .setExpirationTime("15m").sign(new TextEncoder().encode(process.env.JWT_SIGNING_KEY)));
    '
  )
}
access_token="$(access_token_for synthetic-skipper)"
outsider_token="$(access_token_for synthetic-outsider)"
refresh_token="$(node -p 'require("node:crypto").randomBytes(32).toString("base64url")')"
refresh_insert="$(SYNTHETIC_REFRESH="$refresh_token" node --input-type=module -e '
  import { createHash, randomUUID } from "node:crypto";
  const hash = createHash("sha256").update(process.env.SYNTHETIC_REFRESH).digest("hex");
  const now = Date.now();
  const values = [randomUUID(), "synthetic-skipper", hash].map(value => "\x27" + value + "\x27");
  console.log("INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, created_at) VALUES (" +
    [...values, now + 30 * 86400000, now].join(", ") + ");");
')"
pnpm -C web exec wrangler d1 execute DB --local --command "$refresh_insert" >/dev/null
```

Create a voyage and enable a local grant in that shell.

```sh
voyage_id="$(node -p 'crypto.randomUUID()')"
voyage_url="http://127.0.0.1:5173/api/voyages/$voyage_id"
curl -fsS -X PUT "$voyage_url" -H "Authorization: Bearer $access_token" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Synthetic crossing","startedAt":"2026-01-01T00:00:00Z"}'
grant="$(curl -fsS -X POST "$voyage_url/sharing" -H "Authorization: Bearer $access_token" \
  -H 'Content-Type: application/json' \
  -d '{"action":"issue","delayS":0,"expiresInS":900}')"
grant_generation="$(jq -r .grantGeneration <<<"$grant")"
```

Open `http://127.0.0.1:5173/v/<slug>` with the slug from that response. Post a synthetic fix and read the owner preview.

```sh
positions="$(GRANT_GENERATION="$grant_generation" node -p 'JSON.stringify({grantGeneration:Number(process.env.GRANT_GENERATION),positions:[{sampleId:crypto.randomUUID(),segmentId:crypto.randomUUID(),capturedAtMs:Date.now(),lat:0,lon:0.02}]})')"
curl -fsS -X POST "$voyage_url/positions" -H "Authorization: Bearer $access_token" \
  -H 'Content-Type: application/json' -d "$positions"
curl -fsS "$voyage_url/sharing" -H "Authorization: Bearer $access_token"
```

For the [iPhone loopback test](../apps/apple/Integrations/VoyageSharing/README.md),
pass the credentials from the same shell to the test runner. The database stores
only the refresh token hash. The app uses the original token in `$refresh_token`.

```sh
export TEST_RUNNER_MADEGOOD_TEST_WORKER_PORT=5173
export TEST_RUNNER_MADEGOOD_TEST_VOYAGE_ACCOUNT=synthetic-skipper
export TEST_RUNNER_MADEGOOD_TEST_VOYAGE_TOKEN="$access_token"
export TEST_RUNNER_MADEGOOD_TEST_VOYAGE_REFRESH_TOKEN="$refresh_token"
export TEST_RUNNER_MADEGOOD_TEST_VOYAGE_OUTSIDER="$outsider_token"
```

## Production follow-ons

Hosted PR previews omit the live namespace and its Durable Object migration. The
local Worker includes both for the loopback acceptance suite.

The live routes require the local opt-in flag, which is absent from the Worker configuration. The local suite verifies that account deletion removes D1 authority, closes live sockets and purges stored positions, settings and alarms before acknowledging deletion. The registry survives failed object cleanup so the same valid token can retry. Mutations that already registered in D1 still pass the object purge fence after asynchronous work. Frames already sent before the fence can remain in a recipient's possession.

The durable R2 cleanup follow-on in [Private voyage sync](private-voyage-sync.md) remains open. A Worker interruption during a concurrent completed upload can leave an object after the account's prefix sweep. This is separate from the live Durable Object purge. Production also needs a durable cleanup trigger instead of relying on a still-valid token to retry, an agreed retention and historical archival policy, request and connection rate limits, URL/log redaction for share credentials, deployed alarm and WebSocket verification, and the Phase 5 phone and overnight passage checks.
