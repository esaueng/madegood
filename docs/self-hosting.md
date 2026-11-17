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
  links it in a comment. Previews use the preview database and bucket.
- Each push to `main` that touches `web/` applies migrations and deploys production.

The workflow needs the `CLOUDFLARE_API_TOKEN` secret (Workers Scripts and D1 edit on
the account) and the repository variables `CLOUDFLARE_ACCOUNT_ID`, `D1_DATABASE_ID`
and `D1_PREVIEW_DATABASE_ID`. `scripts/cloudflare-config` writes the IDs into the
runner's copy of `wrangler.jsonc`; the repository keeps the placeholders. A fork can
use the same workflow with its own secret and variables.

## Database migrations

- The schema lives in `web/src/server/db/schema.ts` (Drizzle).
- `pnpm -C web db:generate` writes a new SQL file to `web/migrations/`, the folder
  `wrangler d1 migrations apply` reads. Never edit a migration that has been applied;
  add a new one.
- Migrations are applied with Wrangler only. The tests apply the same files.

## Secrets

Secrets (signing keys, Apple credentials; arriving in Phase 3) are set with
`wrangler secret put` and locally in `web/.dev.vars`, which is gitignored. They are
never committed.
