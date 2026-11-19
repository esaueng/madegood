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
| 2. Create D1 and R2 | Cloudflare | [Cloudflare resources](#cloudflare-resources) |
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
```

Put the printed `database_id` into `web/wrangler.jsonc` **in your deployment copy
only**, or let `scripts/cloudflare-config` fill it in at deploy time (below). The
upstream repository keeps the placeholder IDs (`00000000-…`).

The Worker also declares a Durable Object (`VoyageLive`, for live Voyage sharing). It
is created by the first `wrangler deploy`, from the `migrations` block in
`wrangler.jsonc`; there is nothing to create by hand. Live sharing is off unless
`VOYAGE_LIVE_LOCAL=1` (local development only for now).

For a separate preview environment (`env.preview` in `wrangler.jsonc`), create
`madegood-preview` and `madegood-tracks-preview` the same way. Previews never touch
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
- Each push to `main` that touches `web/` builds, applies migrations, then deploys
  production.

Set in the repository (Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | secret | An API token with Workers Scripts edit and D1 edit on the account (plus R2 edit if the workflow should create buckets; it does not today) |
| `CLOUDFLARE_ACCOUNT_ID` | variable | Your account ID |
| `D1_DATABASE_ID` | variable | The `madegood` database's ID |
| `D1_PREVIEW_DATABASE_ID` | variable | The `madegood-preview` database's ID |

`scripts/cloudflare-config` writes the IDs into the runner's copy of `wrangler.jsonc`;
the repository keeps the placeholders. Set the `JWT_SIGNING_KEY` secret on both Workers
once by hand (above); the workflow does not manage secrets.

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
- After changing API routes, run `scripts/generate-openapi` and commit
  `openapi/openapi.json`; the Swift client is generated from it.

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
  default visibility), hashed refresh tokens, session metadata and summaries, and
  privacy zones. R2 holds each session's gzipped track v1 under the user's prefix.
- `DELETE /api/me` deletes the user's rows and every R2 object under their prefix.
- Workers observability is on in `wrangler.jsonc` (`observability.enabled`), so
  Cloudflare keeps request logs for your account; turn it off there if you do not want
  them.
