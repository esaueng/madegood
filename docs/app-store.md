# App Store review materials (draft)

> [!IMPORTANT]
> Draft for the owner to confirm. Everything here comes from reading the code at the
> time of writing (PLAN.md §8 Phase 4, §11). Check it against the build you submit, and
> against Apple's current App Store Connect questions, which change from time to time.
> Nothing here has been submitted.

## Open items before submission

These came up while drafting. Each one would change an answer below or is likely to
get a rejection.

| # | Item | Why it matters |
|---|---|---|
| 1 | ~~No in-app account deletion.~~ Done: iPhone Settings → Account → Delete Account and the website's Settings page both call `DELETE /api/me` after a confirmation. | Guideline 5.1.1(v). |
| 2 | ~~Sign in with Apple tokens are not revoked on deletion.~~ Nothing to revoke: the server never holds an Apple refresh or access token. The iPhone sends only the identity token; the website asks Apple for `code id_token` (required by `form_post`) but verifies the identity token and never redeems the code. No Sign in with Apple private key is needed. If a later change redeems the code, it must store the refresh token and call Apple's `/auth/revoke` on deletion. | Apple asks apps to revoke tokens they hold when an account is deleted. |
| 3 | ~~No privacy policy.~~ Done: the website serves it at `/privacy`, linked from the landing page footer and iPhone Settings → About → Privacy Policy (`MADEGOOD_SITE_URL` in `Config/MadeGood.xcconfig`). Use `<site>/privacy` as the App Store Connect privacy policy URL. | Required in App Store Connect for every app, and for HealthKit apps in particular. |
| 4 | ~~No privacy manifest.~~ Done: `App/Resources/PrivacyInfo.xcprivacy` and `Watch/Resources/PrivacyInfo.xcprivacy` declare tracking off, the collected types in the label table below, and the required-reason APIs in use: UserDefaults (CA92.1), system boot time via `ProcessInfo.systemUptime` (35F9.1 for on-device timers; 8FFB.1 for the absolute timestamps calculated from it, motion samples and clock anchors in each recording, which leave the device with the recording; since raw recording v2 (#87) no file holds the boot-time reading itself, and every way a recording leaves the phone sends version 2 only: Share raw recording (#87) and Export All Recordings (#91), which converts an older recording first) and file timestamps of the app's own recordings (C617.1). No disk-space or active-keyboard APIs are used; the widget extensions use none of these APIs. | Apps that use required-reason APIs must declare a reason in a privacy manifest. |
| 5 | **TestFlight builds have no sync.** `MADEGOOD_API_URL` is empty in `apps/apple/Config/MadeGood.xcconfig`, and CI has no `Local.xcconfig`. | Reviewers would see "Account sync isn't set up in this build." The label answers below assume sync is on; if it ships off, most of the "collected" rows go away. |
| 6 | ~~Health permission strings.~~ Done: the Health, motion and location strings in `Project.swift` now say what the app does (saves workouts with route and heart rate; motion counts paddle strokes). | Reviewers check that purpose strings describe what the app actually does (5.1.1(i)). |
| 7 | ~~No full data export.~~ Done (#79): the website's Settings → Export your data starts a background export (`POST /api/me/exports`; status and parts from `GET /api/me/exports/{id}`), and iPhone Settings → Your Data → Export All Recordings zips the recordings on the phone. | Not an App Store requirement; the privacy policy describes it. |
| 8 | ~~Listing copy predates #77–#102.~~ Done: [Listing](#listing) has the final name, subtitle, promotional text, description, keywords, URLs and What's New, with character counts. It covers the start line (#77), iPhone man-overboard (#81), public profiles and route previews (#95, #96), heart-rate zones (#97), windsurf planing and gybes (#100), the anchor alarm (#101) and stroke intervals (#102), and leaves out Voyages. | Metadata must describe what the build does (2.3.1). |
| 9 | ~~Purpose strings predate the start line, iPhone man-overboard and the anchor alarm.~~ Done: both location strings in `Project.swift` name start-line pings and man-overboard marks, and the iPhone one names the anchor alarm; the AlarmKit string names the GPS backup alarm; the Health read string names heart-rate zones; the motion string says the samples stay on the device. | 5.1.1(i), as item 6. |
| 10 | ~~Label and policy predate public profiles, route images and rate limiting.~~ Done: the label section below covers the public profile (#95), route preview images (#96), rate limiting (#98) and the anchor alarm, and `/privacy` describes all four. | The label and the policy must match what the service processes. |
| 11 | **No support page.** madegood.app has no `/support` route. The proposed Support URL is the privacy policy's contact section (GitHub issues). | App Store Connect requires a Support URL that leads to a way to contact the developer. A dedicated page with a contact address is safer. |
| 12 | **The Voyages tab ships in Release builds.** Recording voyages and legs on the iPhone is reachable from the tab bar; sync and live sharing are off in Release. The listing does not mention Voyages. | Decide whether to hide the tab for 1.0 or describe it in the listing and review notes. A reviewer may ask about a tab the metadata does not describe. |

## Privacy nutrition label

**Tracking: No.** The app contains no third-party SDKs, analytics, advertising or
crash reporting, and links no data with other companies' data for advertising. No
`NSUserTrackingUsageDescription`, no IDFA.

**Without an account** (the default), nothing leaves the device except an optional
Apple Weather request (below) and what the user chooses to send to Apple Health or to
share as a file. Apple's definition of "collected" covers data sent off the device to
the developer or its partners, so with sync off the app collects nothing.

**With an account and sync on**, the following goes to the MadeGood API (a Cloudflare
Worker run by the developer). Proposed answers:

| App Store category | Data type | Collected | Linked to the user | Used for tracking | Purpose | What it is in the code |
|---|---|---|---|---|---|---|
| Location | Precise location | Yes | Yes | No | App Functionality | The session's GPS track (track v1 in R2), its bounding box and start geohash (D1), privacy zone centers |
| Health & Fitness | Health | Yes | Yes | No | App Functionality | Heart rate samples in the track, average and max heart rate in the summary |
| Health & Fitness | Fitness | Yes | Yes | No | App Functionality | Sport, distance, speed, moving time, laps, speed categories |
| User Content | Other user content | Yes | Yes | No | App Functionality | Session title and notes, visibility setting |
| Identifiers | User ID | Yes | Yes | No | App Functionality | Apple's stable user identifier (`apple_sub`), the account ID and handle. The handle is public on the profile page while the user has a public session (below) |
| Contact Info | Name | Yes, optional | Yes | No | App Functionality | The display name Apple shares on first sign-in, if the user allows it. Shown on the public profile and its link preview while the user has a public session. Email is not requested (`requestedScopes = [.fullName]`) |
| Diagnostics | — | No | — | — | — | No crash or analytics SDK. Cloudflare request logs (Workers observability) hold IP addresses and URLs for the account owner; confirm whether to declare them or turn observability off |

Not collected: email, phone, contacts, photos, browsing or search history, purchases,
financial info, sensitive info, device ID, advertising data, audio, raw wrist motion
(the 100 Hz motion stream never leaves the phone unless the user shares a raw recording
file themselves).

**Apple Weather.** On-device local conditions and the optional sailing wind comparison
use WeatherKit with coordinates rounded to a 0.1° grid.

**Server-side Open-Meteo.** Since #72 the server asks Open-Meteo automatically, for unlisted
and public sessions only: the center of the session's zone-cut bounds rounded to 0.1°
(about 11 km) and the UTC dates, nothing else (`web/src/server/lib/wind.ts`); the answer
is stored with the session. Proposed: not declared as collected (it is not retained for the developer),
but described in the privacy policy. Confirm.

**Local conditions.** Off until the user taps Show on the start screen (or turns on
Settings > Weather > Local Conditions). The last answer is kept on the phone. It uses
the existing When In Use location permission, whose iPhone prompt mentions local
conditions.

**Anchor alarm.** The anchor point, swing radius and GPS fixes stay on the iPhone
(`AnchorWatch`); nothing about the alarm is sent anywhere, with or without an
account. The alarms themselves are scheduled with the system through AlarmKit.

**Data shared publicly.** A session is private by default. The owner can make it
unlisted or public; then the website shows its track (with privacy zones cut out),
stats, title and notes to anyone with the link, but not heart rate. This is
user-initiated sharing, not collection by a third party; the privacy policy explains it.

**Public profile (#95).** `/u/<handle>` shows the handle, the display name (if Apple
shared one), totals, and the account's public sessions: sport, title, start time,
duration, distance and speeds, with no track, notes or bounds. To anyone else the
profile exists only while the account has at least one public session; otherwise the
API and the page answer exactly as for an unknown handle, and the Open Graph tags are
generic and `noindex`. Unlisted sessions never appear. Nothing new is collected: the
handle and name are already in the table above.

**Route preview images (#96).** For an unlisted or public session, the Worker draws a
1200 × 630 PNG of the route with privacy zones cut out, plus the sport, distance and
duration, for link previews (`/s/<id>/og.png`, `web/src/server/lib/og-image.ts`). It
is rendered on request from the stored track and kept in Cloudflare's edge cache for up
to five minutes; nothing is written to D1 or R2. Private, deleted and unprocessed
sessions get the brand image. Chat apps and social sites that unfurl a link fetch the
image, as anyone with the link could. Nothing new is collected.

**Rate limiting (#98).** Sign-in and token refresh allow 60 requests a minute per
client IP address (`CF-Connecting-IP`); session uploads allow 1,200 a minute per
account (`web/src/server/lib/rate-limit.ts`). Both use Cloudflare's Workers rate
limiting bindings with 60-second windows: the IP address or account ID is the counter
key, Cloudflare holds the counter, and MadeGood writes neither to D1, R2 or a log of
its own. A refused request gets HTTP 429 with `Retry-After: 60`. Proposed: not declared,
since the address is used only to answer the request and is not retained by the
developer. Cloudflare's own request logs are the Diagnostics question in the table.
Confirm.

## HealthKit

Entitlement: `com.apple.developer.healthkit` on the iPhone and watch apps (no clinical
records, no background delivery).

| | Types |
|---|---|
| Write (share) | Workouts (`HKWorkoutType`), workout routes (`HKSeriesType.workoutRoute()`). Heart rate and energy are added by `HKLiveWorkoutBuilder` during the workout |
| Read | Heart rate |

Draft justification for App Review:

> MadeGood records watersports sessions (sailing, windsurfing, kayak, canoe, SUP,
> motorboating). On Apple Watch and iPhone it runs an `HKWorkoutSession` so recording
> continues with the screen off, reads heart rate during the session to show it live
> with the current heart-rate zone and in the session summary (time in each zone),
> and, if the user keeps "Save to Health" on for that
> sport, saves the session to Health as a workout with its route. Motorboating is not
> saved to Health unless the user turns it on. Health data is not used for advertising
> and is not shared with third parties. If the user signs in and turns on sync, heart
> rate recorded in a session is uploaded with that session to their private MadeGood
> account so they can view it on the website; it is deleted with the session or the
> account.

Heart-rate zones (#97) add no HealthKit types. Zones come from the heart-rate samples
the session already records and a maximum heart rate the user sets in the app (190 bpm
to start); the app does not read age, date of birth or resting heart rate from Health.
Checked against `WorkoutSource.requestAuthorization`: share workouts and workout routes,
read heart rate, nothing else.

Purpose strings (items 6 and 9, in `apps/apple/Project.swift`):

- `NSHealthShareUsageDescription`: "MadeGood reads your heart rate during a session to
  show it live, with your heart-rate zone, and in your session summary."
- `NSHealthUpdateUsageDescription`: "MadeGood saves your sessions to Health as
  workouts, with the route and heart rate, if you turn on Save to Health."

## Background location

The iPhone app declares `UIBackgroundModes: location` and asks only for **When In Use**
authorization (`NSLocationWhenInUseUsageDescription`); nothing requests Always. Each
background use is started by the user and holds a `CLBackgroundActivitySession`, so iOS
shows the background location indicator throughout:

- **A recording** (`SessionRecorder`), from Start to Stop.
- **A Voyage leg** (`VoyageRecorder`), from Start Leg to its end (see open item 12).
- **The anchor alarm** (`AnchorWatch`), only while armed. It runs standard updates
  through `CLLocationManager` with `allowsBackgroundLocationUpdates` and
  `pausesLocationUpdatesAutomatically = false`, so fixes keep arriving while the boat
  lies still. Setup is foreground only; Disarm invalidates the background session.
- **Man-overboard without a recording** (`ManOverboard`), while the MOB screen needs
  guidance or a press is waiting for its first fix, so a mark made during a countdown,
  a mirrored watch session or with nothing running keeps getting fixes when the phone
  locks. During a recording, MOB uses the recording's fixes.

Start-line pings during a countdown (`StartLineController`) and local conditions use
foreground location only (`CLServiceSession`, no background session). The watch app
uses `workout-processing` during its workout session.

Draft justification for App Review

> MadeGood records a GPS track of a session on the water. Users put the iPhone in a dry
> bag, a pocket or a mount and turn the screen off, often for hours during a motorboat
> trip, a sailing race or a long paddle. Recording must continue in the background for
> the track, distance and speed to be correct. The user explicitly starts and stops
> recording. MadeGood uses When In Use permission and the system shows the location
> indicator throughout. On Apple Watch, recording runs inside a HealthKit workout session.
> Motorboat sessions are usually recorded on the iPhone alone, without a watch.
>
> On iPhone, Record → Anchor alarm lets a boat operator explicitly arm a drift
> warning at a chosen point and swing radius. The alarm is a supplementary boating
> safety aid. It needs precise location while the screen is locked because the
> boat may remain at anchor for hours and start to drift at any time. The iPhone
> evaluates drift locally and uses the user's Alarms permission to sound a system
> alarm on the Lock Screen. MadeGood uses When In Use location authorization and
> shows the background location indicator while monitoring. Disarm ends background
> location for the alarm and removes the stored anchor point. Checking the boat
> remains the operator's responsibility.
>
> Man-overboard marks a position with a touch and hold and then guides the user back
> to it with distance and bearing. If no recording is running, MadeGood keeps
> receiving location in the background until the mark is cleared, because the phone
> may be locked or pocketed during a recovery.

The drift detector needs a running app and usable GPS fixes. A pending system alarm
asks the operator to check the anchor and GPS if usable fixes near the swing circle
stop arriving for about two minutes. Force-quitting stops drift monitoring until
the app is reopened. The pending GPS backup alarm can still sound. The user
controls the Alarms permission in Settings. Turning it off also disables Lock Screen
sound for subsequent warnings.

**AlarmKit.** The iPhone app has `NSAlarmKitUsageDescription` and asks for the Alarms
permission (`AlarmManager.requestAuthorization`) only when the user taps Arm anchor
alarm for the first time; it is not requested at launch. It schedules two kinds of
system alarm, both only while the anchor alarm is armed: the drift alarm, when three
distinct confident fixes fall outside the swing radius, and the GPS backup alarm,
renewed while usable fixes arrive and left to sound about two minutes after they stop.
Disarm cancels both. No other feature uses AlarmKit.

### Purpose strings

Checked against the code for this draft (items 6 and 9). The iPhone and watch share
the Health and motion strings; each app has its own location string. No Always,
Bluetooth, camera, photos, microphone, contacts, tracking or Local Network string is
needed: nothing uses those APIs.

| Key | App | String |
|---|---|---|
| `NSLocationWhenInUseUsageDescription` | iPhone | "MadeGood records your track, speed and course during a session, including with the screen off. It also uses your position for start-line pings and man-overboard marks, for local conditions if you turn them on, and to watch for drift while the anchor alarm is armed." |
| `NSLocationWhenInUseUsageDescription` | Watch | "MadeGood records your track, speed and course during a session, including with the screen off, and uses your position for start-line pings and man-overboard marks." |
| `NSAlarmKitUsageDescription` | iPhone | "MadeGood sounds an alarm if your boat drifts outside the swing radius you set, or if GPS stops updating while the anchor alarm is armed." |
| `NSMotionUsageDescription` | Both | "MadeGood records motion during a session to count paddle strokes. The samples stay in the recording on your devices." Motion is recorded at 100 Hz in every sport and used live for strokes in kayak, canoe and SUP. |
| `NSHealthShareUsageDescription` | Both | See [HealthKit](#healthkit). |
| `NSHealthUpdateUsageDescription` | Both | See [HealthKit](#healthkit). |

## Account and deletion

- An account is optional. Everything works offline without one; Sign in with Apple is
  the only sign-in method, on the iPhone (Settings → Account) and the website.
- **Deletion:** iPhone Settings → Account → Delete Account, and the website's Settings
  page → Delete account. Each asks for confirmation, then calls `DELETE /api/me` with the
  ID of the account shown (the server refuses any other, so a stale confirmation cannot
  delete whoever is signed in now). The server marks the account deleting and revokes every
  sign-in at once: it can no longer sign in, read or write. It then removes the D1 rows
  (sessions, privacy zones, voyages and legs) and every R2 object, retrying on the
  scheduled sweep until done, and deletes the account record about 20 minutes later
  (`web/src/server/lib/account-deletion.ts`). The response is 202. Afterwards the iPhone
  signs out, removes the upload queue, frozen tracks, saved tokens and that account's
  sync consent; the website's session cookies are cleared in the same response.
  Recordings on the device are kept (they were never only in the account).
- **Exports:** the first deletion pass also deletes the account's export jobs, and their
  parts go with the rest of its R2 objects; an export step still running stops and
  deletes what it wrote.
- **Sign in with Apple:** no Apple tokens are held, so none are revoked (item 2).
- Confirmation text (iPhone): "Delete your MadeGood account? This deletes every session
  you have uploaded, your privacy zones, your settings and your sign-in from MadeGood's
  servers. Recordings on this iPhone and your Apple Watch stay on your devices, and
  workouts in Apple Health are not affected. This can't be undone."

## Export

- **Per session (iPhone):** session detail → Export GPX (GPX 1.1 track), and Share raw
  recording (the raw NDJSON folder, zipped: always raw format 2 and only the recording's
  own files; an older recording is converted, #87). The detail screen warns that exports
  contain precise locations and times.
- **Apple Health:** saved workouts and routes are exportable through Health.
- **Files app:** recordings live in the app's Documents folder, visible in Files
  (`UIFileSharingEnabled`).
- **All recordings (iPhone):** Settings → Your Data → Export All Recordings zips every
  recording on the phone, one folder each, exactly as Share raw recording sends it: raw
  format 2 (an older recording is converted through the same streaming converter and
  cache) and only the recording's own files, never an interrupted transfer's staging copy
  or the derived track. So no device-uptime reading leaves the phone, which the 8FFB.1
  boot-time declaration relies on. A folder that is not a readable recording is left out
  and counted in a message; a storage error fails the export instead. It then opens the
  share sheet. Export files are deleted when
  the share sheet finishes, and any left over are deleted at launch.
- **Account-wide export (website):** Settings → Export all my data starts a background
  job (`POST /api/me/exports`). It freezes the list of sessions and voyages, then builds
  ZIP parts in R2 (at most 500 MiB each): session and voyage documents, then every track
  as uploaded. Part 1 holds `README.txt`, `account.json` (profile, settings, Apple user
  identifier), `privacy-zones.json`, `manifest.json` (every part and file) and, if needed,
  `errors.json` (files that could not be included, with the reason; a session document
  over 256 KiB is one). The page shows progress, then a download link per part and, if
  anything was left out, how many items and a pointer to `errors.json`, which the README
  also names at the top; the parts are deleted after 7 days. One
  export at a time, three a day.

## Review notes (draft)

Paste the quoted block into App Store Connect → App Review Information → Notes. Replace
the sync paragraph with "Sync is turned off in this build" if item 5 is still open.

> MadeGood records sailing, windsurfing, kayak, canoe, SUP and motorboat sessions on
> iPhone and Apple Watch. It is not for navigation, and its speeds are personal
> records, not certified measurements. An account is optional: everything below except
> sync works without signing in.
>
> **Recording on land.** On iPhone, open Record, tap any sport and allow location.
> Walk or drive: speed, distance and the map update from GPS. Tap Stop, then open the
> session in History for the map, charts, laps, splits and replay. Sport metrics such
> as tacks, planing time or paddle strokes need real time on the water; the attached
> screen recording shows them.
>
> **Start line.** In Settings, open Sailing and set Countdown to 1 min. On the Record
> tab, tap Sailing to start the countdown, then tap the two ping buttons to mark each
> end of the line (walk a few metres between them). Distance to the line, time to burn
> and line bias appear under the countdown.
>
> **Man-overboard.** On the Record tab, touch and hold MOB for about half a second. The
> man-overboard screen shows distance and bearing back to the mark. Clear removes it.
>
> **Anchor alarm (iPhone).** On the Record tab, tap Anchor alarm below the sport list
> (it is also on a live motorboat session, and is hidden only if Motorboating is
> hidden). Allow location, with Precise Location on.
> Tap Use current position, choose the smallest swing radius (10 m), and tap Arm
> anchor alarm. iOS then asks for the Alarms permission; allow it. Lock the phone and
> walk about 30 m from where you armed it. After three GPS fixes outside the circle,
> a system alarm sounds on the Lock Screen. Stop silences it for two minutes while the
> phone is still outside; Disarm in the app ends monitoring. If GPS stops updating for
> about two minutes while armed, a GPS backup alarm sounds instead.
>
> **Why location runs in the background for hours.** Recording keeps running with the
> screen off because the phone is in a dry bag or pocket for the whole session. The
> anchor alarm is a boating safety aid: a boat can lie at anchor for hours, often
> overnight, and start to drag at any time, so drift has to be checked while the phone
> is locked. Man-overboard keeps receiving location until the mark is cleared. Each is
> started by the user, uses When In Use permission, shows the location indicator, and
> stops on Stop, Disarm or Clear. AlarmKit is used only by the anchor alarm, to sound
> the drift and GPS backup alarms on the Lock Screen.
>
> **Sign in with Apple and account deletion.** Settings → Account → Sign in with Apple
> turns on sync. Signed-in sessions can be viewed and shared at https://madegood.app.
> Settings → Account → Delete Account deletes the account and everything uploaded to
> it after a confirmation; recordings on the device stay. The website's Settings page
> has the same Delete account action.

Not in the note, for the owner:

- The synthetic demo modes (`-demoSession`, `-demoOCS`, `-demoOffWater`) are Debug-only
  launch arguments (`DemoFeed.isEnabled` is `false` in Release), so App Review cannot
  use them. Use them for the screen recording of sport metrics and for screenshots.
- A real on-water screen recording (or a `-demoSession` one, labelled as synthetic)
  helps, since reviewers cannot test tacks, planing, gybes or stroke rate on land.
- Steps above match the UI at the time of writing (`AnchorAlarmView`, `ManOverboardViews`,
  `StartLinePanel`). Walk through them on the submitted build.

## Listing

Final copy for App Store Connect. Counts are characters as App Store Connect counts them
(Unicode characters, including spaces and punctuation), checked with Python's `len`.

| Field | Limit | Count | Text |
|---|---|---|---|
| Name | 30 | 30 | MadeGood: Sail & Kayak Tracker |
| Subtitle | 30 | 30 | Windsurf, SUP, Canoe & Boating |
| Promotional text | 170 | 154 | Record sailing, windsurfing, paddling and motorboat sessions on Apple Watch and iPhone. No account needed, and sessions stay private until you share them. |
| Keywords | 100 | 98 | `paddle,paddleboard,dinghy,regatta,race,GPS,speed,speedsurf,anchor,motorboat,tack,gybe,VMG,nautical` |
| Support URL | — | — | https://madegood.app/privacy#contact (until a support page exists; item 11) |
| Marketing URL | — | — | https://madegood.app |
| Privacy Policy URL | — | — | https://madegood.app/privacy |
| What's New (1.0) | 4,000 | 128 | First release on the App Store. Record sailing, windsurfing, kayak, canoe, SUP and motorboat sessions on Apple Watch and iPhone. |

- **Name:** kept from PLAN §1. The subtitle names the other four sports, and the
  keywords repeat no word from the name or subtitle, since App Store search already
  indexes those.
- **Keywords:** no spaces after commas, no plurals of indexed words, no competitor or
  trademark names. "paddle" and "paddleboard" cover canoe and SUP searches;
  "speedsurf", "tack", "gybe" and "VMG" are the metrics; "anchor" is the alarm.
- **What's New:** App Store Connect shows this field only from the second version, so
  it may not appear for 1.0. Keep the text for a 1.0.x release note if so.
- **Promotional text** can change without a new build, so it stays general; use it
  later for news.
- **Description:** 2,975 of 4,000 characters. It claims only what this build does,
  says "Not for navigation", says the account is optional, and leaves out Voyages.

```text
MadeGood records your time on the water with Apple Watch, iPhone, or both. Start a session, put the phone in a dry bag or the watch on your wrist, and review your track, speed and sport-specific numbers afterwards. You don't need an account: sessions are recorded and stored on your devices.

SAILING
• Tacks and gybes, a wind direction estimate, and VMG upwind and downwind
• Start countdown with a start line: ping the pin and the boat end, then see distance to the line, time to burn, line bias and an OCS warning at the gun
• Compare a session's wind estimate with Open-Meteo's modelled wind

WINDSURFING
• Speedsurfing bests: 2 s, 10 s, 5×10 s, 500 m, nautical mile and alpha 500
• Planing time against a threshold you set, and estimated gybes

KAYAK, CANOE AND SUP
• Stroke rate, stroke count and distance per stroke
• Stroke intervals of 100 strokes in replay, to compare one part of a paddle with another

MOTORBOATING
• Trip log in nautical miles, engine time and a fuel estimate
• Anchor alarm on iPhone: arm it at your anchor point with a swing radius, and the iPhone sounds a system alarm if the boat drifts outside it, or if GPS stops updating

ON APPLE WATCH
• Start from your wrist and see live speed, distance and heart rate with your heart-rate zone
• Mark a man-overboard position and get a bearing and distance back to it
• Lock the screen against spray
• The watch records on its own and hands the session to your iPhone

ON IPHONE
• Record with the screen off, with a Live Activity on the Lock Screen
• Man-overboard: touch and hold to mark a position, then steer back with distance and bearing
• Optional local conditions on the start screen, from Open-Meteo
• Review each session with a speed-colored map, charts, laps, 1 km splits, time in heart-rate zones and replay; trim the start or end
• Export any session as GPX

APPLE HEALTH
Save sessions to Apple Health as workouts with the route and heart rate. You choose per sport.

OPTIONAL ACCOUNT
Sign in with Apple to sync sessions to madegood.app, where you can browse, replay and share them. Every session is private until you share it. An unlisted session is visible to anyone with its link; a public one also appears on your public profile. Privacy zones cut places you choose, like home, out of shared tracks. Shared links preview with a route image. You can export everything in your account and delete the account from the app or the website.

PRIVACY
No ads, no analytics, no tracking. Without an account, your sessions stay on your devices unless you share or export them.

NOT FOR NAVIGATION
Maps, the start line, man-overboard and the anchor alarm are aids. They depend on GPS and on the app running, and they don't replace a lookout, charts or proper seamanship. Speeds are personal records, not certified measurements.

OPEN SOURCE
MadeGood is open source under Apache 2.0. The apps, the algorithms and the website are on GitHub.

Requires iOS 26. The Apple Watch app requires watchOS 26.
```

- **Category:** Sports (primary), Health & Fitness (secondary). Confirm.
- **Age rating:** 4+ (no objectionable content; no unrestricted web access; no
  user-to-user communication). Shared sessions show user-written titles and notes on the
  website, not in the app. Confirm the user-generated content answer in
  the current questionnaire.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` is set (HTTPS only).
- **Screenshots:** the CI UI tests export screenshots of the synthetic `-demoSession`
  data (`xcrun xcresulttool export attachments`). They are 1206 × 2622 (a 6.3-inch
  iPhone); App Store Connect requires its current largest iPhone size, so run the UI
  tests on that simulator for the submission set, and add Apple Watch screenshots.
  Use demo data only, never a real session.
