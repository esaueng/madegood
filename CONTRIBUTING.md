# Contributing to MadeGood

Thanks for helping. MadeGood is an open-source (Apache 2.0) app for time on the
water: iPhone and Apple Watch apps plus a website. [docs/PLAN.md](docs/PLAN.md) is
the source of truth for scope, stack, layout, and the roadmap. Read it before
starting anything larger than a small fix.

## Ways to help

- **Recordings.** Real sessions with ground truth (stroke counts, tack times, wind
  direction) are the most valuable thing you can give. See `fixtures/README.md`
  (Phase 0) for how to anonymize and label them. Never commit a raw recording.
- **Bugs and metric accuracy.** Use the issue forms. For a wrong metric, attach an
  anonymized track and what the right value was.
- **Code.** Pick an issue labeled `good first issue` or `help wanted`, or open an
  issue first for anything that changes behavior, formats, or the API.

## Developer Certificate of Origin (DCO)

We use the [Developer Certificate of Origin 1.1](https://developercertificate.org/)
instead of a CLA. By signing off a commit, you certify that you wrote the change or
otherwise have the right to submit it under the project's license.

Sign off every commit with `-s`:

```sh
git commit -s -m "Add stroke detector band-pass filter"
```

This adds a trailer that must match the commit author:

```
Signed-off-by: Your Name <you@example.com>
```

A CI check rejects pull requests with unsigned commits. To fix the last commit, run
`git commit --amend -s --no-edit`; for several, run
`git rebase --signoff origin/main` and force-push your branch.

## Development setup

Each area builds on its own. You only need the tools for the part you change.

| Area | Path | Needs |
|---|---|---|
| Algorithms | `packages/WaterKit` | Swift 6.2 toolchain (macOS or Linux) |
| iPhone + Watch apps | `apps/apple` | macOS, Xcode 26, [Tuist](https://tuist.dev) |
| Website + API | `web` | Node 24, pnpm 10 |

The exact commands are in [AGENTS.md](AGENTS.md#commands); they apply to people too.

### Apple apps and your own signing team

The bundle ID prefix (`app.madegood`) and signing team come from
`apps/apple/Config/Local.xcconfig`, which is gitignored. Copy
`Local.xcconfig.example`, set your own team ID and, for a fork, your own prefix.
Never commit a team ID, certificate, provisioning profile, or API key.

### Website and API

`web/wrangler.jsonc` uses placeholder resource IDs. Local development runs against
local D1 and R2 emulation, so no Cloudflare account is needed. Secrets go in
`web/.dev.vars`, which is gitignored.

## Pull requests

- One focused change per pull request, branched from `main`.
- Include tests: unit tests for WaterKit and the API, accuracy fixtures for metric
  changes. Bug fixes need a regression test.
- Run the checks for the area you touched (see AGENTS.md) before pushing.
- Keep units SI internally (m, s, m/s, degrees true); convert only for display.
- Describe what you changed, why, and how you tested it. Screenshots help for UI.
- Pull requests are squash-merged. The pull request title becomes the commit title.

## Privacy

Location data is personal. Do not put real coordinates, dates, device names, or
personal identifiers in issues, fixtures, logs, screenshots, or tests. Use
`scripts/anonymize-track` (Phase 0) on any track you share.

## Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). Report security
problems as described in [SECURITY.md](SECURITY.md), not in public issues.
