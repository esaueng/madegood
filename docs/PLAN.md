# Build Plan

An open-source (Apache 2.0) app for time on the water: iPhone + Apple Watch apps and
a website. Two modes share one tracking engine:

- **Sessions** (watch-first): workout-style tracking for sailing, windsurfing,
  motorboating, kayak, canoe, and SUP, with sport-specific metrics.
- **Voyages** (iPhone-first, sailing-focused): passage logging over hours or days,
  planned routes and waypoints, live position sharing, and boat instrument data (NMEA).

Sessions ship first (Phases 0–4); Voyages build on the same engine, storage, and
backend (Phases 5–6).

Name: **MadeGood** · domain **madegood.app** · App Store name
"MadeGood: Sail & Kayak Tracker" (the App Store caps names at 30 characters) ·
bundle prefix `app.madegood` (forks override it in `Local.xcconfig`) · GitHub repo
`esaueng/madegood` (the Esau Engineering organization).

---

## 1. Goals and non-goals

**Goals (v1)**

- Sports: sailing, windsurfing (incl. wing/kite later), motorboating, kayak, canoe, SUP.
- Start/stop from Apple Watch or iPhone; either device can run a session alone.
- Sport-specific metrics: tacks/gybes, VMG, speedsurfing categories, stroke rate,
  distance per stroke, anchor alarm, man-overboard.
- Local-first: works offline with no account. Sync and the website are optional.
- Website to browse, replay, and share sessions.
- Voyages: multi-day passage log, routes and waypoints with live navigation data,
  live position sharing on the web, and boat instruments over Wi-Fi (NMEA 0183 / Signal K).
- Easy for contributors and coding agents to work on.

**Non-goals (v1)**

- Android or Wear OS.
- Certified speed records (GPS-TC style). Ours are personal bests.
- A certified chartplotter. Routes use OpenSeaMap/NOAA overlays and are labeled
  "not for navigation". No official (ENC/S-63) chart licensing.
- Weather routing, AIS, satellite (offshore) tracking.
- Social feed, comments, likes.

---

## 2. Stack (decided)

| Area | Choice |
|---|---|
| iOS + watchOS apps | Swift 6, SwiftUI, HealthKit, CoreLocation, CoreMotion, Swift Charts, MapKit (sessions are stored as files, see §8 Phase 1 task 4) |
| Xcode project | Tuist (generated project; no `.xcodeproj` merge conflicts) |
| Shared algorithms | `WaterKit` Swift package (pure Swift, no Apple-only frameworks, so it tests on Linux CI) |
| Website + API | TypeScript, one Cloudflare Worker: React (Vite + `@cloudflare/vite-plugin`) SPA + Hono API under `/api` |
| UI kit | Tailwind, shadcn/ui, TanStack Router, TanStack Query |
| Maps / charts (web) | MapLibre GL (`react-map-gl`), Protomaps tiles in R2, OpenSeaMap overlay, Recharts |
| Data | D1 (Drizzle ORM) for metadata, R2 for track files, Queues for post-upload jobs |
| API contract | Zod schemas → OpenAPI (`@hono/zod-openapi`) → Swift client (`swift-openapi-generator`) |
| Auth | Sign in with Apple (iOS + web), our own JWT access + refresh tokens |
| Weather | Open-Meteo (historical + forecast wind) |
| Tooling | pnpm workspaces, Biome, Vitest + `@cloudflare/vitest-pool-workers`, swift-format, GitHub Actions |
| Minimum OS | iOS 26 / watchOS 26 (needed for iPhone-only workout sessions) |

---

## 3. Repository layout

```
apps/apple/                 Tuist project
  Project.swift
  App/                      iOS app target
  Watch/                    watchOS app target
  Widgets/                  widgets, complications, Live Activity
  Shared/                   code shared by iOS + watch (session engine, sensors, storage)
  Config/                   xcconfigs; Local.xcconfig (gitignored) holds team ID + bundle prefix
packages/WaterKit/          Swift package: models, filters, analyzers, track codec, replay CLI
web/                        Vite + React + Hono Worker
  src/client/               React app
  src/server/               Hono API, queue consumer, D1 schema (Drizzle)
  migrations/               D1 migrations
  wrangler.jsonc
openapi/                    generated openapi.json (committed; Swift client builds from it)
fixtures/                   small anonymized sessions + ground-truth labels (see §9)
scripts/                    fetch-fixtures, anonymize-track, codegen
docs/                       this plan, architecture notes, metric definitions
AGENTS.md                   conventions for coding agents (commands, layout, rules)
LICENSE  NOTICE  CONTRIBUTING.md (DCO)  CODE_OF_CONDUCT.md  SECURITY.md
```

---

## 4. Architecture

### 4.1 Data flow

```
Watch sensors ──► Session engine (Shared) ──► live analyzers ──► watch UI
      │                    │
      │ mirrored workout   └──► local store (recording + track files)
      ▼                                   │
iPhone (live view / standalone session)   │ on finish: post-analysis (WaterKit)
                                          ▼
                              upload queue (background URLSession)
                                          ▼
                    Worker /api ──► D1 (summary) + R2 (track.json.gz)
                                          ▼
                              Queue job: wind lookup, bbox/geohash
                                          ▼
                                   Website (React)
```

- The **watch never calls the API**. It hands finished sessions to the phone
  (`WCSession.transferFile`). During a session, live data goes to the phone through
  HealthKit workout mirroring (`startMirroringToCompanionDevice`, `sendToRemoteWorkoutSession`).
- The **iPhone can run sessions alone** (`HKWorkoutSession` on iOS 26), which matters
  for motorboating and phone-in-a-drybag use.
- **Device-generated UUIDs** for sessions, so uploads are idempotent and retryable.

### 4.2 Sensors

| Signal | API | Rate |
|---|---|---|
| Location, speed, course | `CLLocationUpdate.liveUpdates(.fitness)` + `CLBackgroundActivitySession` (iPhone) | 1 Hz |
| Route for Health | `HKWorkoutRouteBuilder` | — |
| Heart rate, energy | `HKLiveWorkoutBuilder` | ~0.2–1 Hz |
| Motion (strokes) | `CMMotionManager` device motion (all watches); `CMBatchedSensorManager` where available | 50–100 Hz |
| Heading | `CLLocationManager` heading (watch Series 5+, iPhone) | ~1 Hz |

Use **Doppler speed** (`CLLocation.speed`) for all speed metrics, not speed derived
from position changes.

### 4.3 WaterKit design

```swift
struct Sample { /* enum: .gps(GPSFix) .hr(HRSample) .motion(MotionSample) .heading(...) .event(...) */ }

protocol LiveAnalyzer {            // causal, runs on device during the session
    mutating func ingest(_ s: Sample)
    var snapshot: LiveMetrics { get }
}

protocol PostAnalyzer {            // non-causal, runs on the whole track after the session
    func analyze(_ track: Track, context: AnalysisContext) -> SportSummary
}
```

- One live + one post analyzer per sport, chosen through a `SportProfile` registry.
- Post-analysis can improve on live (e.g. wind direction needs the whole track).
- `analyzerVersion` is stored with every summary so sessions can be re-analyzed later.
- All units SI inside (m, s, m/s, degrees true). Converted only at display time.
- `waterkit-replay` CLI: `swift run waterkit-replay <session> [--sport kayak]` prints
  metrics. Used by tests, agents, and algorithm work.

### 4.4 Formats

**Raw recording (debug/research only, local):** a session folder with one NDJSON file
per stream (`gps.ndjson`, `motion.ndjson`, `hr.ndjson`, `events.ndjson`, `meta.json`),
zipped for export. Large (~50 MB/h at 100 Hz) but trivial to read and inspect.

**Track v1 (stored + uploaded):** gzipped JSON, column-oriented:

```json
{
  "v": 1,
  "sessionId": "uuid", "sport": "sailing", "startedAt": "2027-05-01T10:00:00Z",
  "gps":   { "t": [0,1,2], "lat": [...], "lon": [...], "spd": [...], "crs": [...], "hacc": [...] },
  "hr":    { "t": [...], "bpm": [...] },
  "events":[ { "t": 312.4, "type": "tack", "data": { "durationS": 8.1, "speedLossPct": 22 } },
             { "t": 900, "type": "lap" }, { "t": 1200, "type": "mob" } ],
  "summary": { ... SportSummary ... },
  "analyzerVersion": "1.0.0"
}
```

Raw motion data is **not** uploaded by default (only with an opt-in "contribute data" setting).

Exports: GPX (all), FIT and TCX (Phase 3+).

---

## 5. Sport metrics and algorithms

Metric definitions get their own doc (`docs/metrics.md`) as each one is built.

### Shared (all sports)
- Duration, moving time, distance, average/max speed (max = best 2 s and 10 s average,
  never a single fix), splits/laps, heart-rate zones, calories (HealthKit).
- GPS cleaning: drop fixes with `hacc > 25 m`, reject implausible acceleration jumps,
  light smoothing of course over ground.
- Auto-pause: per sport (on for paddling, off by default for sailing/motor).
- **Man-overboard**: one tap or the Action button marks position and time, then shows
  bearing and distance back to it.

### Paddling (kayak, canoe, SUP)
- **Stroke detection:** user acceleration + rotation rate → project onto the main axis of
  movement (PCA over a 5 s window) → band-pass 0.3–3 Hz → peak detection with an
  adaptive threshold and a minimum gap between strokes.
- Kayak: one wrist cycle = 2 strokes (left + right). Canoe/SUP: one cycle = 1 stroke,
  with side-switch detection from the change in wrist orientation.
- Metrics: stroke rate (SPM), stroke count, distance per stroke, side balance/switches,
  splits, intervals.
- **Accuracy target:** stroke count within ±3 %, SPM within ±2 against the labeled fixtures.

### Sailing
- **Maneuvers:** smoothed course change > 60° within ≤ 20 s, with a speed dip.
  Tack vs gybe decided by whether the bow crossed the wind (upwind) or downwind.
- **Wind direction:**
  - Post-session: upwind course histogram → two peaks 70–110° apart → wind direction
    is the line midway between them; Open-Meteo resolves which of the two opposite
    directions is correct.
  - Live: Open-Meteo forecast fetched at start, a user-set direction, or auto after the first two tacks.
- VMG = SOG × cos(true wind angle); upwind/downwind VMG, pointing angle, time and
  distance on each tack.
- **Race tools:** countdown timer (5-4-1-0, sync to the nearest minute, haptics), ping the
  pin and boat ends of the start line, distance to the line, time to burn.
- **Accuracy target:** ≥ 95 % of labeled tacks/gybes detected, < 5 % false positives,
  wind within ±10° of the label.

### Windsurfing / wing
- Speedsurfing categories from Doppler speed: 2 s peak, 10 s average, best 5×10 s,
  100 m, 500 m, nautical mile, 1 hour, alpha 500 (fastest 500 m run whose end is within
  50 m of its start).
- Gybe count, % of time planing (speed above a per-user threshold).

### Motorboating
- Trip log in nautical miles, speed, engine time, fuel estimate (user enters burn rate).
- **Anchor alarm** (iPhone-first): set the anchor point and radius; alert when GPS drifts
  outside it, with a short delay to ignore one-off jumps. Runs in the background for hours.
- Not saved as a Health workout unless the user opts in.

---

## 5b. Voyages mode

A **Voyage** (e.g. "Summer cruise to Catalina") groups **Legs** (one departure to one
arrival). Each leg has a track, log entries, and optionally a planned **Route** (ordered
waypoints). Voyages reuse the Sessions engine, track format, sync, and backend.

### Passage log
- iPhone records (iPad later); the watch is a companion for glances, MOB, and quick log
  entries. Recording uses `CLLocationUpdate.liveUpdates(.otherNavigation)` +
  `CLBackgroundActivitySession`, with no HealthKit workout.
- Adaptive sampling for multi-day battery life: 1 Hz for display, stored every 5–10 s
  underway (more often when turning), and a low-power mode when moored or anchored
  that wakes on movement. Auto-detects departure and arrival.
- Log entries: one-tap buttons (engine on/off, reef/sail change, waypoint passed,
  watch change, note, photo) plus an automatic hourly entry (position, COG, SOG,
  barometric pressure from the iPhone barometer, wind from instruments or Open-Meteo).
- Stats: distance, time underway, time under sail vs motor, day's runs (noon to noon),
  nights at sea, average/max speed. Export the log as PDF/CSV and the track as GPX.

### Routes and waypoints
- Plan routes on the phone or the website (synced), import/export GPX routes.
- Following a route: active waypoint, bearing and distance to it, cross-track error,
  velocity made good on course, ETA / time to go, auto-advance on arrival radius,
  laylines to the waypoint when wind is known.
- Maps: MapKit + OpenSeaMap seamark overlay; NOAA chart tiles as an optional US layer;
  offline region downloads. Clearly labeled "not for navigation".

### Live position sharing
- The phone posts positions in batches (e.g. every 5 min) when it has a connection;
  offshore, positions queue and backfill when back in range.
- Public page `/v/:slug` shows the boat live, the track, and log highlights. Options: share
  link only, delayed position (e.g. 1 hour), hide while in home port.
- One Durable Object per active voyage holds recent positions and pushes updates to
  viewers over WebSockets; D1/R2 keep the history.

### Boat instruments (NMEA)
- Connect over the local network to a Wi-Fi gateway: **NMEA 0183** over TCP/UDP
  (most gateways convert NMEA 2000) and **Signal K** (open-source JSON over WebSocket).
- Sentences/paths: wind (MWV), depth (DPT/DBT), boat speed (VHW), heading (HDG),
  position (RMC), engine RPM, transducer data (XDR).
- Derived: true wind from apparent wind + boat speed + heading, measured polars,
  depth log, engine hours. Feeds sailing metrics (better VMG and tack detection) in
  both Voyages and Sessions.
- Parser lives in WaterKit (pure Swift) and is tested against recorded NMEA logs.
- Needs the iOS Local Network permission.

---

## 6. App UX

### Watch
1. **Start:** sport tiles (last used first) → optional race countdown → go.
2. **Session pages** (swipe):
   - Metrics: 3–4 big fields, configurable per sport.
   - Sport page: strokes/SPM, or maneuvers + VMG + wind arrow, or speed categories.
   - Map with track and MOB marker.
   - Controls: pause, lap, end, water lock, MOB.
3. **Summary** after End, then sync to the phone.
- Action button (Ultra): start / lap / MOB (configurable). Haptics for laps, timer,
  alarms. Complication to start a session.

### iPhone
- **Tabs:** Sessions, Voyages, History, Settings.
- **Voyages tab (Phase 5):** active voyage dashboard (speed, COG, next waypoint, XTE,
  ETA, wind/depth when instruments are connected), log entry buttons, route planner,
  share-link controls, instrument connection.
- **Home:** start button, sport picker, recent sessions.
- **Live:** mirrored from the watch or standalone; Live Activity on the Lock Screen.
- **Session detail:** map colored by speed, maneuver/stroke markers, stats, Swift Charts
  (speed, HR, SPM), maneuver list, splits, share/export.
- **History:** list + simple totals.
- **Settings:** units (kn / km/h / mph, m / nm / mi), per-sport fields, auto-pause,
  privacy zones, account, Health permissions, data export, delete account.

### Website
- `/` landing (what it is, download, GitHub).
- `/s/:id` session page: map + replay scrubber + stats + charts + maneuvers.
  The Worker adds Open Graph tags to the HTML so shared links show a preview.
- `/v/:slug` voyage page: live boat position, legs, track, log highlights (Phase 5).
- `/routes` route planner that syncs to the phone (Phase 5).
- `/u/:handle` public profile (public sessions only).
- `/sessions` dashboard (my sessions, totals), `/settings` (privacy zones, visibility
  default, export all data, delete account).

---

## 7. Backend (Cloudflare)

### D1 schema (first draft)

```
users          id, apple_sub (unique), handle (unique), display_name, units,
               default_visibility, created_at, deleted_at
refresh_tokens id, user_id, token_hash, expires_at, created_at, revoked_at
sessions       id (device UUID), user_id, sport, title, notes, visibility
               (private|unlisted|public), started_at, ended_at, duration_s, moving_s,
               distance_m, max_speed_mps, avg_speed_mps, min_lat, min_lon, max_lat,
               max_lon, start_geohash, summary_json, analyzer_version, track_key,
               wind_json, created_at, updated_at, deleted_at
privacy_zones  id, user_id, lat, lon, radius_m

-- Phase 5 (Voyages)
voyages        id, user_id, title, boat_name, visibility, share_slug, share_delay_s,
               started_at, ended_at, summary_json, created_at, updated_at, deleted_at
legs           id, voyage_id, from_name, to_name, started_at, ended_at, distance_m,
               track_key, route_id, summary_json
log_entries    id, leg_id, t, type, lat, lon, data_json
routes         id, user_id, name, created_at, updated_at
waypoints      id, route_id, seq, name, lat, lon, arrival_radius_m
```

Sessions are **private by default**. Public/unlisted views have privacy zones cut out on
the server before the track is returned.

### API (v1)

```
POST   /api/auth/apple            Apple identity token → access + refresh token
POST   /api/auth/refresh
GET    /api/me   PATCH /api/me   DELETE /api/me     (delete = D1 rows + R2 objects)
GET    /api/me/export                               (zip of all data)
GET    /api/sessions?cursor=
PUT    /api/sessions/:id           upsert metadata + summary (idempotent)
PUT    /api/sessions/:id/track     gzipped track v1 → R2, enqueue post-processing
GET    /api/sessions/:id           respects visibility
GET    /api/sessions/:id/track     privacy zones applied for non-owners
PATCH  /api/sessions/:id           title, notes, visibility
DELETE /api/sessions/:id
GET    /api/users/:handle          public profile + public sessions
GET    /api/health

-- Phase 5 (Voyages)
CRUD   /api/voyages, /api/voyages/:id/legs, /api/legs/:id/log, /api/routes
POST   /api/voyages/:id/positions  batch of live positions → Durable Object + D1
GET    /api/live/:slug             WebSocket for viewers (respects share delay)
```

- Auth: verify the Apple identity token against Apple's public keys with `jose`; issue a
  15-minute access JWT plus a rotating refresh token (stored hashed). The web uses an
  HttpOnly cookie.
- Queue consumer: fetch Open-Meteo wind for the session time and area, compute
  bbox/geohash, and later render a static map thumbnail for Open Graph previews.
- Rate limits on auth and upload with the Workers rate limiting binding.

### Environments
- `production` and per-PR **preview** versions through Workers Builds; separate D1/R2 for
  preview. Secrets (`JWT_SIGNING_KEY`, Apple Services ID/keys) live only in Wrangler secrets.
- `wrangler.jsonc` in the repo has placeholder IDs, so a fork can deploy its own copy by
  following `docs/self-hosting.md`.

---

## 8. Phases

Each phase ends with a checkable exit criterion. Tasks are sized for one agent PR each.

### Phase 0: Foundations
1. Repo hygiene: LICENSE, NOTICE, CONTRIBUTING (DCO), CODE_OF_CONDUCT, SECURITY, AGENTS.md, issue/PR templates.
2. Tooling: pnpm workspace, Biome, Tuist project with iOS + watch targets, `Local.xcconfig.example`.
3. WaterKit skeleton: `Sample`/`Track` models, track v1 codec, raw NDJSON reader, unit tests.
4. **Raw recorder app:** watch + phone start/stop a HealthKit workout and log GPS, motion
   (100 Hz), HR, heading, and manual "mark" events to NDJSON; watch → phone transfer;
   share the zip from the phone (AirDrop/Files).
5. `waterkit-replay` CLI reads a raw session and prints basic stats.
6. Web skeleton: Worker with `/api/health`, React page, D1 + R2 bindings, first migration,
   deployed to a preview URL.
7. CI: WaterKit tests (Linux), iOS/watch build (macOS runner), web lint/typecheck/test.
8. `scripts/anonymize-track` and the fixtures layout (§9).

**Exit:** a real paddle and a real sail recorded on the water, the files open in the replay CLI, CI is green.

### Phase 1: MVP tracker (paddling + basic sailing)
1. Session engine in `Shared/`: sensor pipeline, GPS cleaning, auto-pause, laps.
2. Watch session UI: start flow, metrics page, map page, controls, summary.
3. iPhone: mirrored live view + standalone sessions + Live Activity.
4. Storage: track files on disk are the store (raw recording + track v1, docs/formats.md), with an in-memory analysis cache keyed by recording, settings and trim; watch → phone handoff. Decided against SwiftData: the files already back history, sync, export and the website, and a second store would need its own migrations.
5. HealthKit save (workout + route + HR), correct activity type per sport.
6. iPhone history + session detail (map colored by speed, stats, speed/HR charts).
7. GPX export, units settings.
8. TestFlight pipeline.

**Exit:** 10 real sessions on TestFlight with no crashes or data loss; a 3-hour watch session finishes with battery to spare (target ≤ 20 %/h).

### Phase 2: Sport intelligence
1. Paddling stroke detection (live + post) and the paddling sport page.
2. Sailing maneuver detection, wind estimation (+ Open-Meteo), VMG, sailing sport page.
3. Race countdown + start line.
4. Windsurf speed categories + speed page.
5. Motorboat profile: nm log, fuel estimate, anchor alarm.
6. Man-overboard on watch and phone.
7. Post-session analysis screens (maneuver list, stroke charts, speed bests).
8. `docs/metrics.md` with each definition.

**Exit:** every metric meets its accuracy target on the fixture set in CI.

### Phase 3: Cloudflare backend + website
1. D1 schema + migrations, Drizzle, OpenAPI generation, Swift client codegen.
2. Sign in with Apple (iOS + web), tokens, account deletion, data export.
3. iPhone sync: upload queue in a background URLSession, retries, status in the UI.
4. Upload endpoints, R2 storage, queue consumer (wind, bbox).
5. Web: dashboard, session page (map, replay, charts), profile, settings.
6. Visibility + privacy zones, Open Graph tags for shared links.

**Exit:** sign in on both sides, a session recorded on the watch shows up on the web within a minute of finishing, shared links preview correctly, privacy zones verified.

### Phase 4: Public launch (Sessions)
- App Store review: privacy nutrition label, HealthKit and background location
  justifications, account deletion, screenshots.
- Landing page, docs (`self-hosting.md`, `metrics.md`), roadmap issues for contributors.

### Phase 5: Voyages
1. Voyage/leg/log-entry models, adaptive multi-day recording on iPhone, auto departure/arrival.
2. Log entry UI (one-tap buttons, hourly automatic entries, barometer), voyage stats, PDF/CSV export.
3. Voyages sync + D1 tables + web voyage page.
4. Routes and waypoints: planner on phone and web, GPX import/export, navigation
   data (bearing, distance, XTE, ETA), OpenSeaMap overlay, offline regions.
5. Live sharing: positions endpoint, Durable Object per voyage, live web page, share
   delay and home-port hiding, offshore queue + backfill.
6. Watch companion: voyage glance, next waypoint, MOB, quick log entry.

**Exit:** a real overnight passage recorded with ≤ 25 % phone battery per 24 h
(screen off), followed live on the web by someone ashore, and a route followed with
correct XTE/ETA.

### Phase 6: Boat instruments
1. NMEA 0183 (TCP/UDP) and Signal K clients, connection UI, Local Network permission.
2. WaterKit parser + recorded NMEA fixture logs.
3. True wind, depth log, engine hours (auto engine on/off log entries), measured polars.
4. Use instrument wind in sailing metrics for Sessions and Voyages.

**Exit:** tested on at least two gateway brands or a Signal K server; true wind within
±5° of the boat's own instruments.

### Later
Segments and leaderboards, clubs/regattas, tides and currents (NOAA), weather
routing, AIS targets, interval workouts with audio cues, iPad chartplotter layout,
more sports (rowing, wing, kite, outrigger, dragon boat).

---

## 9. Testing

- **Fixtures:** `fixtures/<sport>/<name>/` with `track.json.gz` (or a trimmed raw folder)
  and `labels.json` (true stroke count, maneuver timestamps, wind direction), labeled
  from video or manual counting.
- **Anonymize before committing:** `scripts/anonymize-track` shifts coordinates to a fake
  origin and drops timestamps' absolute date. This keeps speed and heading but hides
  where you sail. Full raw corpus lives in a public R2 bucket, pulled by `scripts/fetch-fixtures`.
- **WaterKit:** unit tests per filter/analyzer + accuracy tests over all fixtures with
  thresholds (§5). Runs on Linux CI.
- **Apps:** simulator location playback from GPX for UI flows; snapshot tests for key screens later.
- **Web/API:** Vitest in the Workers runtime (real D1/R2 bindings locally), API contract
  tests against the OpenAPI spec.

---

## 10. Decisions still open

| Decision | Needed by | Notes |
|---|---|---|
| Apple Developer account (team ID) | Phase 0 task 4 | Needed for device builds, HealthKit, TestFlight |
| ~~TestFlight via Xcode Cloud or GitHub Actions + fastlane~~ | Phase 1 | Decided: GitHub Actions with plain `xcodebuild` and an App Store Connect API key, no fastlane (docs/releasing.md) |
| ~~Fixture data hosting: public R2 bucket vs Git LFS~~ | Phase 0 | Decided: public R2 bucket, with checksums pinned in Git (fixtures/README.md) |

## 11. Risks

- **GPS on the wrist is noisy** (1 Hz, arm movement, wet antenna); Ultra's dual-frequency GPS helps. Mitigate with Doppler speed and windowed bests.
- **Battery** with GPS + 100 Hz motion + screen. Mitigate by lowering the motion rate when not paddling and using always-on display dimming.
- **Stroke detection varies** with paddle style and which wrist the watch is on. Mitigate with a varied fixture set and a short in-app calibration.
- **App Store review** of background location for motorboat/anchor use. Justify clearly; anchor alarm is a recognized safety use.
- **D1 has no geospatial index.** Bbox + geohash covers v1; revisit for segments.
- **Navigation liability.** Routes and charts must be labeled "not for navigation", with a
  first-run disclaimer; never present OpenSeaMap data as official charts.
- **Multi-day background recording** on iPhone can be killed by iOS or drain the battery.
  Mitigate with adaptive sampling, recovery after relaunch, and a dropout indicator.
- **No coverage offshore** for live sharing. Queue and backfill; satellite trackers are out of scope.
- **Instrument variety.** NMEA output differs across gateways; rely on recorded logs from
  real boats and Signal K as the common format.
