# Roadmap

The state of each [PLAN.md](PLAN.md) phase: what has merged (by pull request) and what
is left. Each "Left" row is sized to become one GitHub issue. Status comes from reading
`main`; real-world checks (battery, on-water accuracy, TestFlight sessions) are marked
**unverified**, because the repository cannot show them.

Legend: ✅ done · 🟡 partly done · ⬜ not started

## Phase 0: Foundations

| Task | Status | Pull requests |
|---|---|---|
| 1. Repo hygiene, policies, templates, DCO | ✅ | #2, #11, #14 |
| 2. Tooling: pnpm, Biome, Tuist, `Local.xcconfig.example` | ✅ | #3 |
| 3. WaterKit skeleton, track v1 codec, raw reader | ✅ | #4 |
| 4. Raw recorder app (watch + phone, NDJSON, transfer, share) | ✅ | #6 |
| 5. `waterkit-replay` CLI | ✅ | #7 |
| 6. Web skeleton (Worker, D1, R2, preview deploy) | ✅ | #9, #33 |
| 7. CI (WaterKit Linux, Apple build, web) | ✅ | #3, #5, #10, #29, #47, #48 |
| 8. `scripts/anonymize-track` and fixtures layout | ✅ | #8 |

**Left**

- ⬜ **Exit criterion:** record a real paddle and a real sail and open them in
  `waterkit-replay`. **Unverified**: the only fixture committed is
  `fixtures/sailing/synthetic-straight-line`.
- ⬜ Decide fixture hosting (PLAN §10: public R2 bucket or Git LFS) and add
  `scripts/fetch-fixtures`.

## Phase 1: MVP tracker

| Task | Status | Pull requests |
|---|---|---|
| 1. Session engine: GPS cleaning, auto-pause, laps | ✅ | #23 |
| 2. Watch session UI (start, metrics, map, controls, summary) | ✅ | #25, #27, #39, #42 |
| 3. iPhone mirrored live view, standalone sessions, Live Activity | ✅ | #26, #30, #45, #52 |
| 4. Storage and watch → phone handoff | ✅ | #6, #31 (track files on disk; SwiftData dropped, #74) |
| 5. HealthKit save (workout, route, HR) | ✅ | #28 |
| 6. iPhone history and session detail | ✅ | #26, #49, #50, #51 |
| 7. GPX export, units settings | ✅ | #24, #39 |
| 8. TestFlight pipeline | ✅ | #35, #46 |

Also merged: watch complication (#32), appearance setting (#43), sport icons and rows
(#41, #44), start countdown keep-awake (#40), 32-bit watch recording fix (#68).

**Left**

- ⬜ **Exit criterion:** 10 real sessions on TestFlight with no crashes or data loss,
  and a 3-hour watch session at ≤ 20 %/h battery. **Unverified.**
- ⬜ Set `MADEGOOD_API_URL` for TestFlight builds (empty in `MadeGood.xcconfig`, so
  TestFlight builds get it from the `MADEGOOD_API_URL` repository variable, #73).
- ✅ Storage decided: track files are the store, no SwiftData (#74; closes #18).

## Phase 2: Sport intelligence

| Task | Status | Pull requests |
|---|---|---|
| 1. Paddling stroke detection and sport page | ✅ | #59 |
| 2. Sailing maneuvers, wind estimate (+ Open-Meteo), VMG, sport page | ✅ | #54, #67 |
| 3. Race countdown and start line | 🟡 | countdown with sync: #39, #40. Start line: not started |
| 4. Windsurf speed categories and speed page | 🟡 | #57. Planing time and gybe count: not started |
| 5. Motorboat profile: nm log, fuel estimate, anchor alarm | 🟡 | log, engine time, fuel: #60. Anchor alarm: not started |
| 6. Man-overboard on watch and phone | 🟡 | watch and Action button: #27, #58. No MOB control found in the iPhone app's UI |
| 7. Post-session screens (maneuver list, stroke charts, speed bests) | ✅ | #50, #54, #57, #59, #67 |
| 8. `docs/metrics.md` | ✅ | with each metric PR, completed in #70 |

**Left**

- ⬜ Start line: ping pin and boat ends, distance to the line, time to burn (watch and
  iPhone).
- ⬜ Anchor alarm on iPhone: anchor point and radius, drift alert with a delay,
  background for hours (see docs/app-store.md for the review justification to add).
- ⬜ Windsurf planing time (per-user threshold) and gybe count.
- ⬜ iPhone man-overboard control with bearing and distance back to the mark.
- ⬜ Heart-rate zones (PLAN §5 shared metrics).
- ⬜ Stroke-based intervals (docs/metrics.md: not built yet).
- ⬜ **Exit criterion:** every metric meets its accuracy target on a labeled
  fixture set in CI. Today the targets are checked on synthetic data only
  (`StrokeDetectorTests`, `SailingWindTests`). Needs labeled real paddling and
  sailing recordings.

## Phase 3: Cloudflare backend and website

| Task | Status | Pull requests |
|---|---|---|
| 1. D1 schema, Drizzle, OpenAPI, Swift client codegen | ✅ | #34, #37 |
| 2. Sign in with Apple (iOS + web), tokens, account deletion, data export | 🟡 | sign-in and tokens: #36, #63. `DELETE /api/me`: #36. No deletion UI, no export |
| 3. iPhone sync: background upload queue, retries, status | ✅ | #65 |
| 4. Upload endpoints, R2, queue consumer (wind, bbox) | 🟡 | uploads: #37. No queue consumer (TODO in `routes/sessions.ts`) |
| 5. Web dashboard, session page, profile, settings | 🟡 | dashboard, session page, settings: #63, #64. No `/u/:handle` profile |
| 6. Visibility, privacy zones, Open Graph | ✅ | #64 |

Also merged: settings sync between devices (#62).

**Left**

- ⬜ Delete Account in the iPhone app (Settings → Account) and on the website settings
  page, calling `DELETE /api/me`; Apple token revocation on deletion.
- ⬜ `GET /api/me/export`: zip of all the user's data, plus a website button.
- ⬜ Queue consumer: bbox and start geohash from the track, Open-Meteo wind into
  `wind_json`, then an Open Graph map thumbnail.
- ⬜ Public profile `/u/:handle` and `GET /api/users/:handle` (public sessions only).
- ⬜ Rate limits on auth and upload (PLAN §7, Workers rate limiting binding).
- ⬜ **Exit criterion:** sign in on both sides, a watch session on the web within a
  minute, shared link previews, privacy zones checked. **Unverified** on production.

## Phase 4: Public launch (Sessions)

| Task | Status | Pull requests |
|---|---|---|
| Landing page | ✅ | #69 |
| Docs: self-hosting, metrics, App Store drafts | ✅ | #70 |
| Roadmap for contributors | ✅ | this file (issues not created yet) |
| App Store review materials | 🟡 | drafted in docs/app-store.md (#70), owner to confirm |

**Left** (details in docs/app-store.md, "Open items")

- ⬜ Account deletion in the app and on the web (shared with Phase 3).
- ⬜ Privacy policy page (for example `/privacy` on the website) and its URL in App
  Store Connect.
- ⬜ `PrivacyInfo.xcprivacy` privacy manifests for the app and extensions.
- ⬜ Fix the Health and motion purpose strings.
- ⬜ App Store screenshots at the required sizes from the demo-session UI tests,
  including Apple Watch.
- ⬜ Public TestFlight link, then set `DOWNLOAD_URL` on the landing page.
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
