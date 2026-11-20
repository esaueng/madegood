# Roadmap

The state of each [PLAN.md](PLAN.md) phase: what has merged (by pull request) and what
is left. Each "Left" row is sized to become one GitHub issue. Status comes from reading
`main`; real-world checks (battery, on-water accuracy, TestFlight sessions, behavior on a
physical watch or iPhone) are marked **unverified**, because the repository cannot show
them.

Legend: ✅ done · 🟡 partly done · ⬜ not started

## Summary

The code for Phases 0–3 is merged. What stands between them and their exit criteria is
real-world verification, which only the owner can do:

1. Record real paddles and sails, anonymize and label them, and publish them to the
   fixture bucket (fixtures/README.md). The Phase 0 and Phase 2 exit criteria need them.
2. Ten TestFlight sessions and a 3-hour watch battery run (Phase 1).
3. Watch → iPhone handoff on physical devices. Simulators drop WatchConnectivity file
   transfers, so the handoff cannot be checked there.
4. The anchor alarm on a locked physical iPhone over several hours.
5. The end-to-end check on production: sign in on both sides, a watch session on the
   web within a minute, shared-link previews, privacy zones (Phase 3).

## Phase 0: Foundations

| Task | Status | Pull requests |
|---|---|---|
| 1. Repo hygiene, policies, templates, DCO | ✅ | #2, #11, #14 |
| 2. Tooling: pnpm, Biome, Tuist, `Local.xcconfig.example` | ✅ | #3 |
| 3. WaterKit skeleton, track v1 codec, raw reader | ✅ | #4 |
| 4. Raw recorder app (watch + phone, NDJSON, transfer, share) | ✅ | #6; raw format 2: #87, #91 |
| 5. `waterkit-replay` CLI | ✅ | #7 |
| 6. Web skeleton (Worker, D1, R2, preview deploy) | ✅ | #9, #33 |
| 7. CI (WaterKit Linux, Apple build, web) | ✅ | #3, #5, #10, #29, #47, #48, #89 |
| 8. `scripts/anonymize-track` and fixtures layout | ✅ | #8 |

Fixture hosting is decided (PLAN §10): a public R2 bucket with checksums pinned in Git,
`scripts/fetch-fixtures`, and accuracy tests over every labeled fixture (#99).

**Left**

- ⬜ **Exit criterion:** record a real paddle and a real sail and open them in
  `waterkit-replay`. **Unverified**: the only committed fixture is synthetic.
- ⬜ Create the public fixture bucket and publish the first labeled recordings
  (fixtures/README.md).

## Phase 1: MVP tracker

| Task | Status | Pull requests |
|---|---|---|
| 1. Session engine: GPS cleaning, auto-pause, laps | ✅ | #23 |
| 2. Watch session UI (start, metrics, map, controls, summary) | ✅ | #25, #27, #39, #42 |
| 3. iPhone mirrored live view, standalone sessions, Live Activity | ✅ | #26, #30, #45, #52 |
| 4. Storage and watch → phone handoff | ✅ | #6, #31 (track files on disk; SwiftData dropped, #74) |
| 5. HealthKit save (workout, route, HR) | ✅ | #28 |
| 6. iPhone history and session detail | ✅ | #26, #49, #50, #51, #88 |
| 7. GPX export, units settings | ✅ | #24, #39 |
| 8. TestFlight pipeline | ✅ | #35, #46, #73, #94 |

Also merged: watch complication (#32), appearance setting (#43), sport icons and rows
(#41, #44), start countdown keep-awake (#40), 32-bit watch recording fix (#68), start
screen reordering and conditions (#75, #90), brand and app icon (#83).

**Left**

- ⬜ **Exit criterion:** 10 real sessions on TestFlight with no crashes or data loss,
  and a 3-hour watch session at ≤ 20 %/h battery. **Unverified.**
- ⬜ Set the `MADEGOOD_API_URL` repository variable so TestFlight builds sync (#73; empty
  in `MadeGood.xcconfig` by design).
- ⬜ Watch → iPhone handoff on physical devices. **Unverified**: simulators report file
  transfers as finished but never deliver them.

## Phase 2: Sport intelligence

| Task | Status | Pull requests |
|---|---|---|
| 1. Paddling stroke detection and sport page | ✅ | #59; stroke-based intervals: #102 |
| 2. Sailing maneuvers, wind estimate (+ Apple Weather), VMG, sport page | ✅ | #54, #67 |
| 3. Race countdown and start line | ✅ | countdown: #39, #40; start line: #77 |
| 4. Windsurf speed categories and speed page | ✅ | #57; planing time and gybes: #100 |
| 5. Motorboat profile: nm log, fuel estimate, anchor alarm | ✅ | #60; anchor alarm: #101 |
| 6. Man-overboard on watch and phone | ✅ | watch and Action button: #27, #58; iPhone: #81 |
| 7. Post-session screens (maneuver list, stroke charts, speed bests) | ✅ | #50, #54, #57, #59, #67 |
| 8. `docs/metrics.md` | ✅ | with each metric PR, completed in #70 |

Also merged: heart-rate zones for every sport (#97).

**Left**

- ⬜ **Exit criterion:** every metric meets its accuracy target on a labeled fixture
  set in CI. The harness is in place (#99); it needs labeled real paddling and sailing
  recordings.
- ⬜ Anchor alarm on a locked physical iPhone: alarm delivery and Stop, several hours in
  the background, battery, permission and clock changes. **Unverified.** Known limits,
  documented in #101: drift alarms more than 5 m outside the swing radius with good GPS,
  and AlarmKit has no atomic cancel.
- ⬜ Anchor alarm follow-ups from the final #101 review (both fail toward ringing, not
  silence): if the app exits between installing the first GPS backup and saving its
  ownership, Stop on that alarm re-alerts after 1 s instead of snoozing 120 s; and the
  alarm screen should mention the cancellation limit, as docs/metrics.md does.
- ⬜ Windsurf planing and gybe accuracy on real recordings. **Unverified.**

## Phase 3: Cloudflare backend and website

| Task | Status | Pull requests |
|---|---|---|
| 1. D1 schema, Drizzle, OpenAPI, Swift client codegen | ✅ | #34, #37 |
| 2. Sign in with Apple (iOS + web), tokens, account deletion, data export | ✅ | #36, #63, #76; deletion: #78; export: #79 |
| 3. iPhone sync: background upload queue, retries, status | ✅ | #65 |
| 4. Upload endpoints, R2, queue consumer (wind, bbox) | ✅ | #37; consumer: #72 |
| 5. Web dashboard, session page, profile, settings | ✅ | #63, #64, #86; profile `/u/:handle`: #95 |
| 6. Visibility, privacy zones, Open Graph | ✅ | #64; route images: #96 |

Also merged: settings sync between devices (#62), rate limits on auth and uploads (#98),
one public address at madegood.app (#85), Cloudflare IDs from secrets (#84).

**Left**

- ⬜ **Exit criterion:** sign in on both sides, a watch session on the web within a
  minute, shared links preview correctly, privacy zones verified. **Unverified** on
  production.
- ⬜ Measure route-image CPU on a deployed preview. Images render on a cache miss
  (capped input), and simultaneous misses each render (#96).
- ⬜ Check the rate limits against real Cloudflare behavior (#98).
- ⬜ Optional: a handle editor on the website (handles change through the API only) and
  a link from a session page to its owner's profile (#95 left this open because it
  would expose the handle on unlisted sessions).

## Phase 4: Public launch (Sessions)

| Task | Status | Pull requests |
|---|---|---|
| Landing page | ✅ | #69 |
| Docs: self-hosting, metrics, App Store drafts | ✅ | #70 |
| Roadmap for contributors | ✅ | this file (issues not created yet) |
| Account deletion in the app and on the web | ✅ | #78 |
| Privacy policy, privacy manifests, purpose strings | ✅ | #82, #93 |
| App Store review materials | 🟡 | drafted in docs/app-store.md (#70), owner to confirm |

**Left** (details in docs/app-store.md, "Open items")

- ⬜ App Store screenshots at the required sizes from the demo-session UI tests,
  including Apple Watch.
- ⬜ Public TestFlight link, then set `DOWNLOAD_URL` on the landing page (still `null`).
- ⬜ App Store Connect listing, nutrition label, review notes, submission (owner).
- ⬜ Turn the "Left" rows on this page into GitHub issues (owner).

## Phase 5: Voyages

| Task | Status | Pull requests |
|---|---|---|
| 1. Voyage/leg models, multi-day recording, auto departure/arrival | 🟡 | offline leg recording with recovery: #53. No adaptive sampling or auto departure/arrival yet |
| 2. Log entry UI, hourly entries, barometer, stats, PDF/CSV | ⬜ | |
| 3. Voyages sync, D1 tables, web voyage page | 🟡 | private sync of completed legs, local opt-in only: #55 (docs/private-voyage-sync.md) |
| 4. Routes and waypoints, navigation data, OpenSeaMap, offline regions | ⬜ | |
| 5. Live sharing (positions, Durable Object, live page, delay, backfill) | 🟡 | loopback-only prototype: #56 (docs/voyage-sharing.md, docs/local-voyage-transport.md) |
| 6. Watch companion | ⬜ | |

**Left**

- ⬜ Adaptive sampling and low-power moored mode; auto departure and arrival.
- ⬜ Log entries (one-tap, hourly automatic, barometer), voyage stats, PDF/CSV export.
- ⬜ Turn on private voyage sync in production (now behind `VOYAGE_PRIVATE_LOCAL`),
  and the `/v/:slug` web voyage page.
- ⬜ Routes and waypoints on phone and web, GPX routes, XTE/ETA, OpenSeaMap overlay
  labeled "not for navigation", offline regions.
- ⬜ Live sharing beyond loopback (now behind `VOYAGE_LIVE_LOCAL`): share delay,
  home-port hiding, offshore queue and backfill, Durable Object migrations on preview.
- ⬜ Watch companion: voyage glance, next waypoint, MOB, quick log entry.
- ⬜ **Exit criterion:** overnight passage at ≤ 25 % battery per 24 h, followed live
  ashore, a route followed with correct XTE/ETA.

## Phase 6: Boat instruments

Not started.

- ⬜ NMEA 0183 (TCP/UDP) and Signal K clients, connection UI, Local Network permission.
- ⬜ WaterKit NMEA parser with recorded fixture logs.
- ⬜ True wind, depth log, engine hours, measured polars.
- ⬜ Instrument wind in sailing metrics.
- ⬜ **Exit criterion:** two gateway brands or a Signal K server; true wind within ±5°.

## Later

From PLAN §8: segments and leaderboards, clubs and regattas, tides and currents,
weather routing, AIS, interval workouts with audio cues, iPad layout, more sports.
