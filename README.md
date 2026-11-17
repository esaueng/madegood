<p align="center">
  <img src="assets/icon.svg" width="96" height="96" alt="MadeGood logo">
</p>

<h1 align="center">MadeGood</h1>

<p align="center">
  Open-source tracking for time on the water, on iPhone, Apple Watch, and the web.
</p>

<p align="center">
  <a href="https://github.com/esaueng/madegood/actions/workflows/ci.yml"><img src="https://github.com/esaueng/madegood/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License: Apache 2.0"></a>
  <img src="https://img.shields.io/badge/platforms-iOS%20%7C%20watchOS%20%7C%20web-lightgrey" alt="Platforms: iOS, watchOS, web">
</p>

MadeGood records sailing, windsurfing, motorboating, kayak, canoe, and SUP sessions
from your wrist or your phone and turns them into sport-specific numbers: tacks and
gybes, VMG, speedsurfing bests, stroke rate. It also keeps a log of longer
passages. It works offline with no account; sync and the website are optional.

The name comes from navigation: *course made good* and *speed made good* describe
where you actually went over the ground, not where you were pointed.

> [!NOTE]
> MadeGood is in early development (Phase 0: foundations). Nothing is released yet,
> and none of it is for navigation.

## What it will do

**Sessions** (watch-first)

- Start and stop from Apple Watch or iPhone; either device can record alone.
- Saves workouts, routes, and heart rate to Apple Health.
- Speed from GPS Doppler, with max speed as a 2 s or 10 s best, never one noisy fix.

| Sport | Metrics |
|---|---|
| Sailing | Tack and gybe detection, wind estimate, VMG, race start timer and line |
| Windsurfing, wing | Speedsurfing categories (2 s, 10 s, 5×10 s, 500 m, nautical mile, alpha 500), planing time |
| Kayak, canoe, SUP | Stroke rate, stroke count, distance per stroke, side switches |
| Motorboating | Nautical-mile trip log, fuel estimate, anchor alarm |
| All | Distance, speed, splits, heart-rate zones, man-overboard mark |

**Voyages** (iPhone-first)

- A passage log over hours or days, with automatic and one-tap log entries.
- Routes and waypoints with bearing, distance, cross-track error, and ETA.
- Live position sharing on the web for people ashore.
- Boat instruments over NMEA 0183 or Signal K.

**Website** (planned for madegood.app): browse, replay, and share sessions.
Sessions are private unless you share them.

See [docs/PLAN.md](docs/PLAN.md) for the full scope, the accuracy targets, and the
roadmap.

## Repository layout

| Path | What's there |
|---|---|
| [`apps/apple/`](apps/apple) | iOS and watchOS apps (SwiftUI, Tuist project) |
| [`packages/WaterKit/`](packages/WaterKit) | Pure-Swift package: models, filters, analyzers, track format, CLIs. Builds on Linux. |
| [`web/`](web) | One Cloudflare Worker: React website and Hono API under `/api` |
| [`fixtures/`](fixtures) | Small anonymized sessions with ground-truth labels |
| [`scripts/`](scripts) | Track anonymizer and CI helpers |
| [`docs/`](docs) | Plan, [file formats](docs/formats.md), [self-hosting](docs/self-hosting.md) |

## Getting started

WaterKit (any macOS or Linux machine with Swift 6):

```sh
swift test --package-path packages/WaterKit
swift run --package-path packages/WaterKit waterkit-replay <session-folder>
```

Website and API (Node.js and pnpm; no Cloudflare account needed locally):

```sh
pnpm install
pnpm -C web db:migrate:local
pnpm -C web dev
```

Apple apps (macOS with Xcode):

```sh
mise install
cd apps/apple && tuist install && tuist generate
```

Put your Apple team ID in `apps/apple/Config/Local.xcconfig` (copy
`Local.xcconfig.example`) to build to a device. To run your own copy of the website,
see [docs/self-hosting.md](docs/self-hosting.md).

## Contributing

Anyone can open an issue: bug reports, wrong metrics, feature ideas, and
anonymized recordings are all welcome. Pull requests are limited to the
project's collaborators. [CONTRIBUTING.md](CONTRIBUTING.md) explains how to
help, and [AGENTS.md](AGENTS.md) lists the commands and conventions for
collaborators and coding agents. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md), and report security issues privately as
described in [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE).

Created in [T3 Code](https://t3.codes).
