# Self-hosting the website and API

The website and API are one Cloudflare Worker (`web/`). This guide grows with the
project; for now it covers the Phase 0 skeleton: a landing page, `GET /api/health`,
a D1 database and an R2 bucket.

## Local development

No Cloudflare account is needed. Wrangler emulates D1 and R2 locally.

```sh
pnpm install
pnpm -C web db:migrate:local   # create the local D1 tables
pnpm -C web dev                # http://localhost:5173, API under /api
```

Local development and tests run on workerd, Cloudflare's runtime, which supports
macOS, Linux and Windows (x64).

## Deploying your own copy

1. Create the resources in your Cloudflare account:

   ```sh
   cd web
   pnpm exec wrangler d1 create madegood
   pnpm exec wrangler r2 bucket create madegood-tracks
   pnpm exec wrangler queues create madegood-postprocess
   pnpm exec wrangler queues create madegood-postprocess-dlq
   ```

2. Put the printed `database_id` into `web/wrangler.jsonc` in **your fork or
   deployment config only**. The upstream repository keeps the placeholder IDs
   (`00000000-…`) so no real account or resource IDs are ever committed.
3. Apply migrations and deploy:

   ```sh
   pnpm exec wrangler d1 migrations apply DB --remote
   pnpm deploy
   ```

`env.preview` in `wrangler.jsonc` describes a separate database and bucket for
preview deployments, so previews never touch production data. Create those the
same way (`madegood-preview`, `madegood-tracks-preview`). The Vite plugin bakes the
environment's bindings into the build output, so select the environment when
**building**, not only when deploying:

```sh
pnpm exec wrangler d1 migrations apply DB --remote --env preview
CLOUDFLARE_ENV=preview pnpm deploy
```

## How the main deployment works

The project's own deployment (`madegood.esau.workers.dev`, previews on
`madegood-preview`) runs from `.github/workflows/deploy.yml`:

- Each pull request that touches `web/` uploads a preview version of
  `madegood-preview` at `pr-<number>-madegood-preview.<subdomain>.workers.dev` and
  links it in a comment. Each PR gets its own D1 database, `madegood-pr-<number>`,
  which is deleted when the PR closes; previews share the preview R2 bucket.
- Each push to `main` that touches `web/` builds, creates the post-processing queues
  if they are missing, applies migrations, then deploys production.

The workflow needs the `CLOUDFLARE_API_TOKEN` secret (Workers Scripts, D1 and Queues
edit on the account) and the repository variables `CLOUDFLARE_ACCOUNT_ID`, `D1_DATABASE_ID`
and `D1_PREVIEW_DATABASE_ID`. `scripts/cloudflare-config` writes the IDs into the
runner's copy of `wrangler.jsonc`; the repository keeps the placeholders. A fork can
use the same workflow with its own secret and variables.

## Database migrations

- The schema lives in `web/src/server/db/schema.ts` (Drizzle).
- `pnpm -C web db:generate` writes a new SQL file to `web/migrations/`, the folder
  `wrangler d1 migrations apply` reads. Never edit a migration that has been applied;
  add a new one.
- Migrations are applied with Wrangler only. The tests apply the same files.
- Production applies migrations just before deploying the new code, so the version
  already running must keep working with the new schema. Change the schema in steps:
  add new columns or tables first (expand), deploy code that uses them, and only drop
  or rename old ones in a later release (contract).

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
the object R2 holds. A new upload or a newer revision clears the derived data at once.

**Privacy zones.** Every zone change bumps the owner's `users.zones_version` in the same
D1 batch. Public data records the version it was cut at, is written only while that
version is still current, and is served only while it matches, so nothing computed
without a zone is shown once the zone exists. The change then queues one `user`
message, which requeues that user's sessions 50 at a time (follow-up messages carry a
cursor). If that message cannot be queued, adding a zone is undone and answers 503, and
removing one answers 503 so the client repeats it.

**Retries and dead letters.** A failure (D1, R2, an Open-Meteo outage or rate limit)
is retried after 30 s, 1, 2, 4 and 8 minutes. After 5 retries the message moves to
`madegood-postprocess-dlq`, which has no consumer: inspect it in the dashboard (Queues
› madegood-postprocess-dlq) and, once the cause is fixed, either re-upload the track
or send the message body back to `madegood-postprocess`. Messages that can never
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
- the UTC calendar dates of the fixes others may see (no time of day);
- the fixed variables `wind_speed_10m,wind_direction_10m,wind_gusts_10m` with
  `wind_speed_unit=ms`, `timeformat=unixtime`, `timezone=GMT`.

No account, session ID, track, title or API key is sent. Open-Meteo's free API is for
non-commercial use; a commercial deployment needs its own Open-Meteo plan. Wind is a
model value for the area, shown as such, and not for navigation.

## Secrets and settings

Secrets are set with `wrangler secret put` and locally in `web/.dev.vars`, which is
gitignored. They are never committed.

| Name | Kind | Purpose |
|---|---|---|
| `JWT_SIGNING_KEY` | secret | Signs API access tokens (HS256). At least 32 characters of randomness. |
| `APPLE_AUDIENCES` | var in `wrangler.jsonc` | Comma-separated Sign in with Apple audiences for the apps: your iOS bundle ID. |
| `APPLE_WEB_CLIENT_ID` | var in `wrangler.jsonc` | Your Sign in with Apple **Services ID** for the website. Empty turns web sign-in off. |

```sh
# Local development: web/.dev.vars
echo "JWT_SIGNING_KEY=$(openssl rand -base64 48)" >> web/.dev.vars

# Each deployed environment gets its own key
cd web
openssl rand -base64 48 | pnpm exec wrangler secret put JWT_SIGNING_KEY
openssl rand -base64 48 | pnpm exec wrangler secret put JWT_SIGNING_KEY --env preview
```

A fork that ships its own app changes `APPLE_AUDIENCES` to its bundle ID. Changing
`JWT_SIGNING_KEY` invalidates outstanding access tokens; clients get a new one with
their refresh token, so nobody is signed out. The key also derives each refresh token's
successor, so a refresh token replayed within 30 s across the change counts as reuse and
signs that user out.

Sign-in fetches Apple's public keys from `https://appleid.apple.com/auth/keys` and
caches them in memory for an hour.

### Web sign-in

The website signs in with Apple's web flow and keeps its tokens in HttpOnly cookies.
In the Apple Developer portal, create a Services ID with Sign in with Apple enabled,
add your domain, and register the return URL
`https://<your domain>/api/auth/web/apple/callback` (Apple requires HTTPS and a
registered domain, so per-PR preview URLs cannot sign in unless registered). Put the
Services ID in `APPLE_WEB_CLIENT_ID`. Users who signed in on the iPhone get the same
account on the web, because Apple uses the same user identifier for an app and its
Services IDs when the Services ID is grouped with the app's primary App ID.
