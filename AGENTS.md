# AGENTS.md

Conventions for coding agents (and people) working in this repository.
[docs/PLAN.md](docs/PLAN.md) is the source of truth for scope, stack, architecture,
and phases. The stack in PLAN.md §2 is decided; do not swap libraries or frameworks
without an issue that changes the plan first.

## Layout

```
apps/apple/        Tuist project: iOS app, watchOS app, widgets, Shared/ code, Config/
packages/WaterKit/ Pure-Swift package: models, filters, analyzers, track codec, CLIs
web/               One Cloudflare Worker: React SPA (src/client) + Hono API under /api (src/server)
openapi/           Generated openapi.json (committed; the Swift client builds from it)
fixtures/          Small anonymized sessions + ground-truth labels
scripts/           anonymize-track, fetch-fixtures, codegen
docs/              Plan, formats, metric definitions, self-hosting
```

Directories appear as Phase 0 lands; check that a path exists before relying on it.

## Commands

Run the checks for every area you touch before you push.

| Area | Command (from the repo root unless noted) |
|---|---|
| WaterKit tests | `swift test --package-path packages/WaterKit` |
| Replay a session | `swift run --package-path packages/WaterKit waterkit-replay <path>` |
| Anonymize a track | `scripts/anonymize-track <in> <out>` |
| Apple project | `mise install` (pins Tuist), then `cd apps/apple && tuist install && tuist generate --no-open` |
| Apple build | see the `apple` job in `.github/workflows/ci.yml` for the exact `xcodebuild` lines |
| Web install | `pnpm install` |
| Web lint/format | `pnpm check` (Biome) |
| Web typecheck/test | `pnpm -C web typecheck && pnpm -C web test` |
| Web dev server | `pnpm -C web dev` |

Each row works once the Phase 0 task that adds it has merged. If a command fails
because its files don't exist yet, say so rather than inventing a replacement.

## Rules

- **Units:** SI everywhere internally (m, s, m/s, degrees true, m/s² for
  acceleration). Convert only at display time.
- **Speed:** use Doppler speed (`CLLocation.speed`), never speed derived from
  position differences. Max speed is a windowed best (2 s, 10 s), never one fix.
- **WaterKit stays pure Swift:** no Foundation-on-Darwin-only APIs, no CoreLocation,
  HealthKit, CoreMotion, or Combine. It must build and test on Linux.
- **Formats are contracts:** the raw recording format and track v1 are versioned
  (see `docs/formats.md`). Changing a field means bumping the version and keeping a
  reader for the old one.
- **The watch never calls the API.** It hands sessions to the phone.
- **Session IDs are device-generated UUIDs**, so uploads are idempotent.
- **Privacy:** sessions are private by default. Never commit real coordinates,
  dates, device names, or personal identifiers; anonymize fixtures with
  `scripts/anonymize-track`.
- **No secrets or account IDs in the repo:** Apple team IDs go in the gitignored
  `apps/apple/Config/Local.xcconfig`; Cloudflare account and resource IDs stay as
  placeholders in `web/wrangler.jsonc`; secrets live in `web/.dev.vars` locally and
  in Wrangler secrets when deployed.
- **Generated files:** do not hand-edit the Tuist-generated Xcode project (it is not
  committed) or `openapi/openapi.json` (regenerate it).
- **Tests:** add a regression test with every bug fix. Metric changes must keep the
  accuracy thresholds in PLAN.md §5 passing on the fixture set. Do not loosen a
  threshold to make a test pass.
- **Labels:** routes and charts are "not for navigation"; never present OpenSeaMap
  or NOAA data as official charts.

## CI

`.github/workflows/ci.yml` runs only the jobs whose files changed (see
`scripts/ci-changes.sh`) and ends in one `CI` job that passes when every job that ran
passed. Require `CI` (plus `DCO sign-off`) on `main`, not the individual jobs, which are
skipped when their area is untouched. Changing `ci.yml` or the script runs everything.

## Pull requests

- One focused change per pull request, branched from `main`, squash-merged.
- Sign off every commit (`git commit -s`); a DCO check enforces it.
- Describe what changed, why, and how it was tested; list anything left unverified
  (for example, behavior only testable on a physical watch).
