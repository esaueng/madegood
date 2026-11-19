# Self-hosting the website and API

The website and API are one Cloudflare Worker (`web/`): the React site as static
assets, and the Hono API under `/api`. It stores account and session metadata in D1
and track files in R2. This guide takes a fork from nothing to a deployed Worker and an
iPhone app that syncs to it.

Placeholders below: `<account>` is your Cloudflare account, `<prefix>` your reverse-DNS
bundle prefix (for example `com.example.madegood`), `<host>` the hostname your Worker is
served on (a custom domain, or `<worker>.<subdomain>.workers.dev`). Never commit real
account IDs, resource IDs, team IDs or secrets (AGENTS.md).

## Checklist

| Step | Where | Section |
|---|---|---|
| 1. Run it locally | your machine | [Local development](#local-development) |
| 2. Create D1, R2 and the queues | Cloudflare | [Cloudflare resources](#cloudflare-resources) |
| 3. Set the JWT secret | Cloudflare | [Secrets and settings](#secrets-and-settings) |
| 4. Apply migrations and deploy | Cloudflare | [Deploying](#deploying) |
| 5. Optional: deploy from GitHub Actions | GitHub | [Deploying from GitHub Actions](#deploying-from-github-actions) |
| 6. App IDs and Sign in with Apple | Apple Developer | [Apple setup](#apple-setup) |
| 7. Point the app at your API | `apps/apple/Config` | [The iPhone app](#the-iphone-app) |
| 8. TestFlight | App Store Connect, GitHub | [docs/releasing.md](releasing.md) |

## Local development

No Cloudflare account is needed. Wrangler emulates D1, R2 and Durable Objects locally.

```sh
pnpm install
pnpm -C web db:migrate:local   # create the local D1 tables
echo "JWT_SIGNING_KEY=$(openssl rand -base64 48)" >> web/.dev.vars
pnpm -C web dev                # http://localhost:5173, API under /api
```

Local development and tests run on workerd, Cloudflare's runtime, which supports
macOS, Linux and Windows (x64). `pnpm -C web test` runs the API tests against local D1
and R2.

A simulator build of the app can sync to the local Worker: set
`MADEGOOD_API_URL = http:/$()/127.0.0.1:5173/api` in `apps/apple/Config/Local.xcconfig`
([The iPhone app](#the-iphone-app)). Sign in with Apple needs a signed build and your
bundle ID in `APPLE_AUDIENCES`.

## Cloudflare resources

```sh
cd web
pnpm exec wrangler login
pnpm exec wrangler d1 create madegood
pnpm exec wrangler r2 bucket create madegood-tracks
pnpm exec wrangler queues create madegood-postprocess
pnpm exec wrangler queues create madegood-postprocess-dlq
pnpm exec wrangler queues create madegood-exports
```

Put the printed `database_id` into `web/wrangler.jsonc` **in your deployment copy
only**, or let `scripts/cloudflare-config` fill it in at deploy time (below). The
upstream repository keeps the placeholder IDs (`00000000-…`).

The Worker also declares a Durable Object (`VoyageLive`, for live Voyage sharing). It
is created by the first `wrangler deploy`, from the `migrations` block in
`wrangler.jsonc`; there is nothing to create by hand. Live sharing is off unless
`VOYAGE_LIVE_LOCAL=1` (local development only for now).

For a separate preview environment (`env.preview` in `wrangler.jsonc`), create
`madegood-preview` and `madegood-tracks-preview` the same way; previews use no queue
([Upload post-processing](#upload-post-processing)). Previews never touch
production data.

## Secrets and settings

Secrets are set with `wrangler secret put`, and locally in `web/.dev.vars` (gitignored).

| Name | Kind | Purpose |
|---|---|---|
| `JWT_SIGNING_KEY` | secret | Signs API access tokens (HS256) and derives refresh-token successors. At least 32 characters of randomness. |
| `APPLE_AUDIENCES` | var in `wrangler.jsonc` | Comma-separated Sign in with Apple audiences for the apps: your iOS bundle ID, `<prefix>`. |
| `APPLE_WEB_CLIENT_ID` | var in `wrangler.jsonc` | Your Sign in with Apple **Services ID** for the website. Empty turns web sign-in off. |
| `APP_VERSION` | var in `wrangler.jsonc` | Shown by `GET /api/health` and in the site footer. |
| `VOYAGE_LIVE_LOCAL`, `VOYAGE_PRIVATE_LOCAL` | `.dev.vars` only | `1` turns on the Voyage prototypes for local development and tests. Leave unset when deployed. |

```sh
cd web
openssl rand -base64 48 | pnpm exec wrangler secret put JWT_SIGNING_KEY
openssl rand -base64 48 | pnpm exec wrangler secret put JWT_SIGNING_KEY --env preview
```

Each environment gets its own key. Changing `JWT_SIGNING_KEY` invalidates outstanding
access tokens; clients get a new one with their refresh token, so nobody is signed out.
A refresh token replayed within 30 s across the change counts as reuse and signs that
user out.

Sign-in fetches Apple's public keys from `https://appleid.apple.com/auth/keys` and
caches them in memory for an hour. No Apple private key is needed: the Worker only
verifies identity tokens.

## Deploying

```sh
cd web
pnpm exec wrangler d1 migrations apply DB --remote
pnpm deploy                     # vite build && wrangler deploy
curl https://<host>/api/health  # {"status":"ok","version":"…","db":"ok"}
```

The Vite plugin bakes the environment's bindings into the build output, so select the
environment when **building**, not only when deploying:

```sh
pnpm exec wrangler d1 migrations apply DB --remote --env preview
CLOUDFLARE_ENV=preview pnpm deploy
```

To serve the site on your own domain, add a custom domain to the Worker in the
Cloudflare dashboard (Workers → your Worker → Settings → Domains and routes). Web
sign-in needs a stable HTTPS hostname registered with Apple ([Apple setup](#apple-setup)).

## Deploying from GitHub Actions

`.github/workflows/deploy.yml` deploys the project's own copy and works unchanged in a
fork:

- Each pull request that touches `web/` uploads a preview version of
  `madegood-preview` at `pr-<number>-madegood-preview.<subdomain>.workers.dev` and
  links it in a comment. Each PR gets its own D1 database, `madegood-pr-<number>`,
  which `deploy-cleanup.yml` deletes when the PR closes; previews share the preview R2
  bucket. Preview versions cannot apply Durable Object migrations, so the preview
  environment has no Durable Object bindings.
- Each push to `main` that touches `web/` builds, creates the post-processing queues
  if they are missing, applies migrations, then deploys production.

**One public address.** Set `CANONICAL_ORIGIN` in `web/wrangler.jsonc` (production `vars`)
and `VITE_CANONICAL_ORIGIN` in the production build step of `.github/workflows/deploy.yml` to
your custom domain (for example `https://madegood.example`). Pages on any other host, such as
the `workers.dev` address, move there; `/api` answers on every host. With a custom domain you can
also turn the production `workers.dev` address off (`"workers_dev": false` in `wrangler.jsonc`,
as this repository does) — then point the deploy workflow's health check at your domain. Register that domain and `https://<domain>/api/auth/web/apple/callback` on the
Sign in with Apple Services ID, and point `MADEGOOD_API_URL` at `https://<domain>/api`.

Set in the repository (Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | secret | An API token with Workers Scripts, D1 and Queues edit on the account (plus R2 edit if the workflow should create buckets; it does not today) |
| `CLOUDFLARE_ACCOUNT_ID` | secret | Your account ID |
| `D1_DATABASE_ID` | secret | The `madegood` database's ID |
| `D1_PREVIEW_DATABASE_ID` | secret | The `madegood-preview` database's ID |

The IDs aren't credentials, but they're secrets rather than variables so GitHub masks them
in the public workflow logs (Cloudflare's CI guides store `CLOUDFLARE_ACCOUNT_ID` the same way).

`scripts/cloudflare-config` writes the IDs into the runner's copy of `wrangler.jsonc`;
the repository keeps the placeholders. Set the `JWT_SIGNING_KEY` secret on both Workers
once by hand (above); the workflow does not manage secrets.

## Database migrations

- The schema lives in `web/src/server/db/schema.ts` (Drizzle).
- `pnpm -C web db:generate` writes a new SQL file to `web/migrations/`, the folder
  `wrangler d1 migrations apply` reads. Never edit a migration that has been applied;
  add a new one. That includes migrations only a PR preview has applied: preview
  databases record them as done and skip a rewritten file.
- Migrations are applied with Wrangler only. The tests apply the same files.
- Production applies migrations just before deploying the new code, so the version
  already running must keep working with the new schema. Change the schema in steps:
  add new columns or tables first (expand), deploy code that uses them, and only drop
  or rename old ones in a later release (contract).
- After changing API routes, run `scripts/generate-openapi` and commit
  `openapi/openapi.json`; the Swift client is generated from it.

## Upload post-processing

After a track upload (`PUT /api/sessions/:id/track`) the Worker sends a message to the
`madegood-postprocess` queue (binding `POSTPROCESS`), and the same Worker consumes it
(`src/server/lib/postprocess.ts`). The consumer reads the stored track and saves:

- the bounding box of the whole track and a 5-character start geohash (owner only);
- the bounding box of the fixes others may see, with privacy zones cut out exactly as
  in the shared track, which is all anyone else ever gets;
- the first and last GPS fix times: the whole track's for the owner, and separately
  the first and last fix others may see, which is all they get;
- for public and unlisted sessions only, hourly modelled wind from Open-Meteo.

The session's `processing` field reports `pending`, `done`, `too_large` or `invalid`.
Tracks above the shared-track caps (8 MiB inflated or 500,000 fixes) are `too_large`
and get no derived data. Tracks uploaded before post-processing existed report `none`
until they are uploaded again.

**Idempotency.** Each message names the session, its upload revision and the stored
track's ETag. Every write requires the row to still hold that exact track, so duplicate
deliveries, older revisions, replaced tracks and deleted sessions are dropped. After
attaching a track, the upload reads the stored object back and moves the row to its
ETag if a concurrent upload of the same revision replaced it, so the row always names
the object R2 holds and the queued message is for those bytes. An upload whose bytes
were replaced that way answers 412 `track_replaced`, never success, so the client sends
it again. A new upload or a newer revision clears the derived data at once.

**Privacy zones.** Every zone change bumps the owner's `users.zones_version` in the same
D1 batch and clears the public bounds, times and wind. Public data (wind included)
records the version it was cut at, is written only while that version is still
current, and is served only while it matches, so nothing computed without a zone is
shown once the zone exists. The change then queues one `user` message, which requeues
that user's sessions 50 at a time (follow-up messages carry a cursor), and records it
in `users.zones_queued_version`. If that message cannot be queued, the change stays
marked pending: the user's next track upload or zone change queues it, and a cron
sweep (`triggers.crons`, every 30 minutes) queues any that are left. Adding a zone that
cannot be queued is undone and answers 503; removing one answers 503 but needs no
retry. Removing a zone that does not exist changes nothing.

**Retries and dead letters.** A failure (D1, R2, an Open-Meteo outage or rate limit)
is retried after 30 s, 1, 2, 4 and 8 minutes. After 5 retries the message moves to
`madegood-postprocess-dlq`, which has no consumer: inspect it in the dashboard (Queues
› madegood-postprocess-dlq) and, once the cause is fixed, either re-upload the track
or send the message body back to `madegood-postprocess`. A dead letter holds only IDs (session,
account, revision, track ETag); Cloudflare deletes it when the queue's message retention
ends (4 days by default; the privacy policy relies on that, so do not raise it without
updating the policy). Messages that can never
succeed (an invalid track, a malformed message) are acknowledged, not retried.

**Without a queue.** Preview versions cannot set queue consumers, so `env.preview` has
no queue. Without the `POSTPROCESS` binding the Worker processes each upload right after
responding (`waitUntil`): one attempt, no retries, no dead letters, and a zone change
reprocesses at most 20 sessions (a `waitUntil` gets about 30 s). The others show no
public data until their next upload or zone change. A self-hosted copy can drop the
`queues` block the same way.

### What is sent to Open-Meteo

Wind is fetched only while a session is public or unlisted; private sessions never
cause a request (sharing a session later queues the lookup). Visibility is read again
right before each request, and the answer is stored only if the session is still
shared. Each request to
`api.open-meteo.com` (sessions that ended within 60 days) or `archive-api.open-meteo.com`
(older ones) carries only:

- one position: the center of the session's **public** bounds, rounded to 0.1°
  (about 11 km), so no point inside a privacy zone shapes it;
- the UTC calendar dates of the first and last fix others may see (no time of day);
- the fixed variables `wind_speed_10m,wind_direction_10m,wind_gusts_10m` with
  `wind_speed_unit=ms`, `timeformat=unixtime`, `timezone=GMT`.

No account, session ID, track, title or API key is sent. Open-Meteo's free API is for
non-commercial use; a commercial deployment needs its own Open-Meteo plan. Wind is a
model value for the area, shown as such, and not for navigation.

## Account export

Settings → Export all my data on the website runs a background job
(`src/server/lib/export-job.ts`):

- `POST /api/me/exports` first inserts the job in one conditional statement (the account
  active, no export running, fewer than three started in the last day), then freezes a
  snapshot (every session's ID, upload revision, track
  key and ETag; every voyage and leg) as JSON in R2 under the user's prefix
  (`users/<id>/exports/<export>/snapshot.json`) and records the job in D1 (`export_jobs`).
  Concurrent requests cannot get past either limit. A failure after the snapshot is
  written deletes it again.
- Each message on `madegood-exports` (batch size 1) claims its step in D1 with an
  attempt token (a claim is protected for 10 minutes), builds one ZIP part into an R2
  multipart upload under a key that includes the token, and commits it by compare-and-swap;
  an attempt that lost its claim deletes only its own objects, and the job's cursor moves
  only from a committed part's listing. Documents come first (sessions in files of 250,
  looked up by the frozen IDs and written one compact JSON line per session, the stored
  summary embedded as is), then tracks by their frozen key and ETag. A part stops at 500 MiB, 400 items or
  700 storage calls, then queues the next step. A track replaced since the snapshot is
  exported at its current version (noted in `manifest.json`); one that is gone, and a
  session document over 256 KiB, is listed in `errors.json`. The job reports how many
  items were left out (`omitted`), and the README names them at the top.
- A failure after a part commits never deletes that part. A job whose snapshot could not
  be deleted after a failed start is kept as failed until the sweep deletes its objects.
- The last step writes part 1 (README, account, privacy zones, manifest, errors) and marks
  the job ready for 7 days.
- The cron sweep deletes expired parts, re-sends the step of a job untouched for 30
  minutes (a lost message), and fails a job still unfinished after 12 hours. Rows of
  expired and failed jobs go after 30 days.
- Without the `EXPORTS` binding (previews), steps run after the response with `waitUntil`
  for up to 20 s, and the sweep continues the rest, so large exports are slow there.
- Account deletion removes the export objects with the rest of the user's prefix, and the
  job rows with the user; a step for an account that is gone or being deleted stops and
  deletes what it wrote.

## Apple setup

Needs an Apple Developer Program membership.

1. **App IDs.** In Certificates, Identifiers & Profiles, register explicit App IDs for
   `<prefix>`, `<prefix>.watchkitapp`, `<prefix>.widgets` and
   `<prefix>.watchkitapp.complications`. Enable HealthKit on the first two and Sign in
   with Apple on the first ([docs/releasing.md](releasing.md)).
2. **Services ID for the website.** Create a Services ID (for example
   `<prefix>.web`), enable Sign in with Apple, choose `<prefix>` as its primary App ID,
   add `<host>` as a domain and register the return URL
   `https://<host>/api/auth/web/apple/callback`. Apple requires HTTPS and a registered
   hostname, so per-PR preview URLs cannot sign in unless each is registered.
3. **Configure the Worker.** Put `<prefix>` in `APPLE_AUDIENCES` and the Services ID
   in `APPLE_WEB_CLIENT_ID` in your `wrangler.jsonc` (both environments), then deploy.

Grouping the Services ID with the app's primary App ID makes Apple use the same user
identifier for both, so someone who signed in on the iPhone gets the same account on
the web.

## The iPhone app

Copy `apps/apple/Config/Local.xcconfig.example` to `Local.xcconfig` (gitignored) and
set:

```
DEVELOPMENT_TEAM = <your team ID>
BUNDLE_ID_PREFIX = <prefix>
MADEGOOD_API_URL = https:/$()/<host>/api
```

`$()` stops xcconfig reading `//` as a comment. The app only accepts an `https` URL, or
`http` to `127.0.0.1` or `localhost`. With `MADEGOOD_API_URL` empty, the app has no
account or sync: it records, saves to Health and exports as usual, all on device.

Then `mise install`, and in `apps/apple`: `tuist install && tuist generate`.

**TestFlight.** [docs/releasing.md](releasing.md) covers the workflow, secrets and App
Store Connect setup. The CI runner has no `Local.xcconfig`, so a TestFlight build gets
`MADEGOOD_API_URL` from `apps/apple/Config/MadeGood.xcconfig`, which is empty upstream:
**TestFlight builds have no sync until it is set there** (an API URL is public, so a
fork can commit its own). A fork also needs `BUNDLE_ID_PREFIX` in that file or passed
to `scripts/testflight` as a build setting.

## Data and deletion

- D1 holds users (Apple's user identifier, a handle, an optional display name, units,
  default visibility), hashed refresh tokens, session metadata and summaries, data
  derived from tracks (bounds, fix times, wind; see
  [Upload post-processing](#upload-post-processing)), and privacy zones. R2 holds each session's gzipped track v1 under the user's prefix.
- `DELETE /api/me` deletes the user's rows and every R2 object under their prefix.
- Workers observability is on in `wrangler.jsonc` (`observability.enabled`), so
  Cloudflare keeps request logs for your account; turn it off there if you do not want
  them.
