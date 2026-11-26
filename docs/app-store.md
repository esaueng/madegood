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
| 4 | ~~No privacy manifest.~~ Done: `App/Resources/PrivacyInfo.xcprivacy` and `Watch/Resources/PrivacyInfo.xcprivacy` declare tracking off, the collected types in the label table below, and the required-reason APIs in use: UserDefaults (CA92.1), system boot time via `ProcessInfo.systemUptime` (35F9.1 for on-device timers; 8FFB.1 for the absolute timestamps calculated from it, motion samples and clock anchors in each recording, which leave the device with the recording; since raw recording v2 (#87) no file holds the boot-time reading itself, and every way a recording leaves the phone sends version 2 or later only: Share raw recording (#87) and Export All Recordings (#91), which converts an older recording first) and file timestamps of the app's own recordings (C617.1). No disk-space or active-keyboard APIs are used; the widget extensions use none of these APIs. | Apps that use required-reason APIs must declare a reason in a privacy manifest. |
| 5 | ~~TestFlight builds have no sync.~~ Done: the owner set the `MADEGOOD_API_URL` repository secret to `https://madegood.app/api`, which the TestFlight workflow writes into the archive (`.github/workflows/testflight.yml`, [releasing.md](releasing.md)). The checked-in `MadeGood.xcconfig` value stays empty, so local builds still show "Account sync isn't set up in this build." Check that Settings → Account offers Sign in with Apple in the archive you submit. | The listing, review notes and label below describe a build with sync configured. |
| 6 | ~~Health permission strings.~~ Done: the Health, motion and location strings in `Project.swift` now say what the app does (saves workouts with route and heart rate; motion counts paddle strokes). | Reviewers check that purpose strings describe what the app actually does (5.1.1(i)). |
| 7 | ~~No full data export.~~ Done (#79): the website's Settings → Export your data starts a background export (`POST /api/me/exports`; status and parts from `GET /api/me/exports/{id}`), and iPhone Settings → Your Data → Export All Recordings zips the recordings on the phone. | Not an App Store requirement; the privacy policy describes it. |
| 8 | ~~Listing copy predates #77–#102.~~ Done: [Listing](#listing) has the final name, subtitle, promotional text, description, keywords, URLs and What's New, with character counts. It covers the start line (#77), iPhone man-overboard (#81), public profiles and route previews (#95, #96), heart-rate zones (#97), windsurf planing and gybes (#100), the anchor alarm (#101) and stroke intervals (#102), and leaves out Voyages. | Metadata must describe what the build does (2.3.1). |
| 9 | ~~Purpose strings predate the start line, iPhone man-overboard and the anchor alarm.~~ Done: both location strings in `Project.swift` name start-line pings and man-overboard marks, and the iPhone one names the anchor alarm; the AlarmKit string names the GPS backup alarm; the Health read string names heart-rate zones; the motion string says the samples stay on the device. | 5.1.1(i), as item 6. |
| 10 | ~~Label and policy predate public profiles, route images and rate limiting.~~ Done: the label section below covers the public profile (#95), route preview images (#96), rate limiting (#98) and the anchor alarm, and `/privacy` describes all four. | The label and the policy must match what the service processes. |
| 11 | ~~No support page.~~ Done (#136): https://madegood.app/support has the contact address support@madegood.app (forwarding tested by the owner), GitHub issues, common questions and the navigation notice. It is the Support URL below. | App Store Connect requires a Support URL that leads to a way to contact the developer. |
| 12 | ~~The Voyages tab ships in Release builds.~~ Done (#138): `MADEGOOD_VOYAGES` is set in Debug only, so Release has no Voyages tab or settings and skips voyage recovery, sync and live sharing. The listing, the review notes and the purpose strings do not mention Voyages. Submit an archive built after #138 merges. | Metadata must describe what the build does (2.3.1). |
| 13 | ~~The iPhone sends weather requests to a non-Apple weather service.~~ Done (#137): local conditions and the sailing wind comparison use Apple WeatherKit with a 0.1° grid cell. Wind for shared sessions uses the WeatherKit REST API since #140: fetched when an unlisted or public session is viewed, kept only in Cloudflare's cache for up to 3 hours, never stored in D1 or exports, and earlier stored wind deleted. Since #141 the iPhone keeps WeatherKit answers only in a purgeable cache in Library/Caches with entry caps (reused for up to 15 minutes for conditions, 1 hour for forecast wind and 24 hours for historical wind; expired entries stay until the app's cleanup at launch or foreground, or iOS purges the cache) and removes the entries older versions stored in preferences; this document and `/privacy` describe that. One-time setup: enable WeatherKit on the iPhone App ID ([releasing.md](releasing.md#enable-apple-weather-on-the-iphone-app-id)). Live WeatherKit answers and the attribution assets are still unverified on a signed build. | The label and the policy below assume WeatherKit for all weather. |
| 14 | **App Review needs a screen recording of a real session.** The demo modes (`-demoSession`, `-demoOCS`, `-demoOffWater`) are Debug-only (`DemoFeed.isEnabled` is `false` in Release), and tacks, gybes, planing, strokes and the start line's time to burn and line bias cannot be shown on land. Record a real session on the water with the Release build and attach it in App Store Connect → App Review Information → Attachment (or link it in the notes). Don't show the precise location of a home or other private place. | Without it, a reviewer can check only speed and distance (2.1, completeness). |
| 15 | **Confirm Cloudflare's production settings (owner, in the dashboard).** #135 turned off persisted Workers observability and Logpush in `wrangler.jsonc`, but nobody has checked the production account and zone. Check: (a) the zone's plan and Security Analytics / Security Events retention (31 days on Free, Pro and Business, 90 days for Security Analytics on Enterprise); (b) that no zone-level HTTP request logging, Logpush or Instant Logs job is configured; (c) that Workers Logs and traces are off for the `madegood` Worker; (d) who has dashboard access to the zone. Then confirm the Coarse Location row and the Diagnostics answer below, and the 31-day figure in `/privacy`. | The label and the policy's IP section depend on what the zone actually retains. |
| 16 | **WeatherKit server key and the 4 Worker secrets set (owner).** #140 reads the WeatherKit key from four Worker secrets: `WEATHERKIT_PRIVATE_KEY`, `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID` and `WEATHERKIT_SERVICE_ID`. Create the WeatherKit key in the Apple Developer account and set them with `wrangler secret put` in production. Never commit them ([self-hosting.md](self-hosting.md)). | Without them, shared sessions get no wind; the policy describes the WeatherKit path. |
| 17 | ~~Session sharing and the public web views of sessions and profiles.~~ Off for now: the server keeps every session private (`SHARING` unset, `web/src/server/lib/sharing-available.ts`), migration `0018_sharing_unavailable` made every unlisted or public session private and turned every public profile off, and neither the website nor the iPhone (`SessionSharing.isAvailable`) shows sharing controls. Nothing a user records is shown to anyone else, so the label has no **Data shared publicly** entry and the listing must not mention sharing. Live voyage sharing was already Debug-only (item 12). | Keeps the app out of location sharing with other people, and the metadata must describe what the build does (2.3.1). |

## Privacy nutrition label

**Tracking: No.** The app contains no third-party SDKs, analytics, advertising or
crash reporting, and links no data with other companies' data for advertising. No
`NSUserTrackingUsageDescription`, no IDFA.

Apple's definition: data is "collected" when it is sent off the device in a way that
lets the developer or its third-party partners access it for longer than it takes to
answer the request in real time. Data processed only on the device is not collected,
and Apple adds: "You are not responsible for disclosing data collected by Apple." It
also says an IP address that is sent on a request and not retained need not be
disclosed, and that a stored IP address is declared "based on how you use IP address,
such as precise location, coarse location, device ID, or diagnostics."
([App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/))
The definition covers data that "you and/or your third-party partners" can access.
The page does not name hosting providers, so this draft treats data that Cloudflare
keeps for the developer, in a form the developer can read, as the developer's own
collection. Where the guidance is ambiguous, the draft declares.

**Without an account** (the default), MadeGood collects nothing: the app sends no
request to the MadeGood API until the user attempts to sign in. What leaves the phone
goes to Apple, not to MadeGood: an optional Apple Weather request (below), Apple Maps
tiles, and what the user chooses to save to Apple Health or share as a file.

**Attempting sign-in** (Settings → Account → Sign in with Apple, or the website) sends
`POST /api/auth/apple` (`web/src/server/routes/auth.ts`) to the MadeGood API, a
Cloudflare Worker run by the developer, with Apple's identity token (it carries Apple's
user identifier) and, if the user allows it, the name Apple shares. That request goes
through Cloudflare on a first sign-in, before any account exists, and also when the
sign-in then fails (invalid token, rate limit, an account still being deleted), so the
IP handling below applies from the first attempt. A sign-in refused for an identity
token that fails verification or for the rate limit writes nothing to D1. One for an
account still being deleted stores no new sign-in data, but after the 20-minute grace
period it can retry the deletion and, if cleanup fails again, update that account's
retry count and next retry time (`deletionAttempts`, `deletionNextAt`) before
answering 409. Once it verifies, `signInAppleSubject`
(`web/src/server/lib/account-deletion.ts`) commits the `users` row through
`findOrCreateUser` (`web/src/server/auth/users.ts`) before `issueTokenPair` runs, so a
sign-in that fails after that (writing the refresh token, or signing the access token,
which can leave the `refresh_tokens` row too) still leaves the account record. No code
removes such a record; it stays until the user deletes the account after signing in
again. The policy says so.

**A successful sign-in** stores, with Sync sessions still off: the `users` row
(`web/src/server/db/schema.ts`: Apple's user identifier `apple_sub`, the account ID, a
generated handle, the name if shared, `units` (default nautical), `default_visibility`
(default private) and `created_at`), and one `refresh_tokens` row
(`web/src/server/auth/tokens.ts`: the SHA-256 hash of the refresh token, its family,
client (`app` or `web`), creation and expiry times, 60 days, and a revoked time once
rotated or signed out). Sessions upload only after the user also turns on **Sync
sessions**, which is off after every new sign-in (`SessionSyncConsent`). The iPhone does
not fetch or show the account's Visibility of new sessions; the server applies it at
upload (`web/src/server/lib/session-upload.ts`), and a static note under **Sync
sessions** says so. While sharing is unavailable (item 17) that default is always private
and the note reads: "Uploaded sessions are private: only you can see them, here and on
madegood.app." Proposed answers, with the
stage at which each type is collected:

| App Store category | Data type | Collected | Linked to the user | Used for tracking | Purpose | What it is in the code |
|---|---|---|---|---|---|---|
| Identifiers | User ID | Yes, at sign-in | Yes | No | App Functionality | Apple's stable user identifier (`apple_sub`), the account ID and handle. Enabled profiles can expose an independent random ID and an optional URL username |
| Contact Info | Name | Yes, at sign-in or in profile settings, optional | Yes | No | App Functionality | The account name Apple shares if the user allows it, plus a separate name the user can enter for their public profile. The chosen profile name is public while the profile is enabled and the account has a public session. Email is not requested (`requestedScopes = [.fullName]`) |
| Location | Precise location | Yes: tracks with Sync sessions on; privacy zones whenever added on the website | Yes | No | App Functionality | The session's GPS track (track v1 in R2), its bounding box and start geohash (D1), uploaded from the iPhone only with Sync sessions on. Separately, privacy zone centers (`privacy-zones.ts`), which a signed-in user saves on the website, from the map or the browser's location, whether or not iPhone sync is on. Covers the rounded server wind lookup below |
| Location | Coarse location | Yes, from the first sign-in attempt (any API request) | Yes | No | App Functionality | The client IP address, and the country Cloudflare shows for it, in sampled request records that zone Security Analytics keeps up to 31 days, used only for security (below) |
| Health & Fitness | Health | Yes, with Sync sessions on | Yes | No | App Functionality | Heart rate samples in the track, average and max heart rate in the summary |
| Health & Fitness | Fitness | Yes, with Sync sessions on | Yes | No | App Functionality | Sport, distance, speed, moving time, laps, speed categories |
| User Content | Other user content | Yes, with Sync sessions on | Yes | No | App Functionality | Session title and notes, visibility setting |
| Diagnostics | — | No | — | — | — | No crash or analytics SDK. The Worker's only console output is a severity and a fixed event code, and persisted logs are off (below) |

Both privacy manifests declare these types, except Coarse Location, which only the
iPhone manifest declares: the watch never calls the API.

Not collected: email, phone, contacts, photos, browsing or search history, purchases,
financial info, sensitive info, device ID, advertising data, audio, raw wrist motion (the 100 Hz motion stream never leaves the
phone unless the user shares a raw recording file themselves).

**Apple Weather on the iPhone (#137).** Local conditions (off until the user taps Show on the start
screen or turns on Settings → Weather → Local Conditions) and the sailing session's
**Compare with Apple Weather** button use WeatherKit. The phone sends Apple only a
0.1° × 0.1° grid cell (`WeatherGridCell`, about 11 km north–south), never the fix
itself; the comparison also asks for the session's hours. While the start screen is
shown, local conditions refresh automatically every 15 minutes; turning them on, or the
card's manual Refresh, fetches sooner. Answers are cached on the phone only temporarily,
as WeatherKit's terms allow (#141): a purgeable cache in Library/Caches
(`WeatherDiskCache`), on the device only, with entry caps. Current conditions are reused
for up to 15 minutes, forecast wind for 1 hour and historical wind for 24 hours, measured
from fetch time (`PhoneWeather`). Those are reuse periods, not retention: an expired
entry stays on disk until the app's cleanup removes it (`PhoneWeather.prune` and
`LocalWeather.prune`, run at launch and whenever the app becomes active, in
`MadeGoodApp.swift`; saving new wind also drops expired wind) or iOS purges the cache.
Entries older versions stored in UserDefaults are removed on upgrade.
MadeGood's server never sees the request. Apple says WeatherKit location "is used only to provide weather
forecasts, is not associated with any personally identifiable information, and is
never tracked between requests" ([WeatherKit](https://developer.apple.com/weatherkit/)).
Apple does not state a retention period there, so the policy doesn't claim one.
Proposed: **not declared.** The data goes to Apple, not to the developer or a partner
whose code is in the app, and Apple's guidance says developers aren't responsible for
disclosing data Apple collects.

**Wind for shared sessions on the website (#72, #140).**
WeatherKit's terms allow only temporary caching, so the server stores no wind. When
someone views an **unlisted or public** session, the website asks the Worker, which asks
Apple's WeatherKit REST API for that session's hourly wind
(`web/src/server/lib/wind.ts`), and the page shows it with Apple Weather attribution.
The request carries one position, the center of the session's bounds with privacy
zones cut out, rounded to 0.1° (`WIND_GRID_DEG`, about 11 km), and the session's
visible time range, as whole UTC hours from an hour before to an hour after
(`windRequest`). No account, session ID or track is sent, and it comes from
Cloudflare, so Apple sees Cloudflare's IP address, never the owner's or the viewer's.
Private sessions never cause a request. The answer is kept only in Cloudflare's edge cache, for up to
3 hours (`WIND_TTL_SECONDS`), keyed by cell and hours with no session or viewer ID
(`cachedWind`). Nothing is written to D1 or R2, data exports no longer include wind,
and wind stored by the earlier lookup is being deleted (#140).
Proposed: **no extra row**, for two reasons: Apple's guidance says developers aren't
responsible for data Apple collects, and the input is derived from the track the
developer already declares under Precise Location. The policy describes the request.

**Anchor alarm.** The anchor point, swing radius and GPS fixes stay on the iPhone
(`AnchorWatch`); nothing about the alarm is sent anywhere, with or without an
account. The alarms themselves are scheduled with the system through AlarmKit.

**Diagnostics and Worker logs (#135).** Every application console entry is a warning or
error holding one fixed `{ event: "<code>" }` object (`web/src/server/lib/logging.ts`).
It never includes user or session IDs, handles, names, emails, Apple identifiers,
coordinates, tokens, request bodies, URLs, headers, IP addresses or error text.
`wrangler.jsonc` sets `"observability": { "enabled": false }` and `"logpush": false`,
so Workers Logs, traces and Logpush don't retain invocations. An operator who opens a
real-time `wrangler tail` sees request URLs, headers and Cloudflare request metadata
while it is open; nothing is stored.

**Cloudflare Security Analytics and the IP address.** Cloudflare, the hosting provider,
processes every client IP at ingress. Separately, the zone's Security Analytics keeps
sampled requests, including those to `/api`, for up to 31 days on the Free, Pro and
Business plans (90 days on Enterprise), and the zone operator can filter them by
source IP and see the URI and Cloudflare's per-request details such as country
([Security Analytics](https://developers.cloudflare.com/waf/analytics/security-analytics/),
[Security Events](https://developers.cloudflare.com/waf/analytics/security-events/)).
How this draft answers, step by step:

1. **Is it collected?** Yes. The record leaves the device, is stored in readable form
   for longer than it takes to answer the request, and the developer can read it.
   Cloudflare keeps it on the developer's behalf, so it is the developer's collection,
   not Apple's "sent on a request and not retained" exception.
2. **Which data type?** Apple classifies a stored IP by use. MadeGood uses these records
   only for security (spotting abuse of sign-in and uploads), never to locate a user,
   identify a device, or debug. But Cloudflare shows a country for each record, which
   is location at lower resolution than three decimal places, and the guidance does not
   say whether location derived by the provider counts when the developer never uses
   it. The conservative answer is **Coarse Location**.
3. **Linked?** **Yes.** The app calls the API only after sign-in, and a sampled URI can
   hold a session ID that maps to an account, so the record could be tied to a user.
4. **Purpose?** **App Functionality**, which Apple defines to include "prevent fraud,
   implement security measures". Not tracking, not advertising, not analytics.
5. **Diagnostics?** **No.** Security use alone is not "measuring technical
   diagnostics", and the Worker's own logs hold no user data (above). If the owner ever
   uses these records to troubleshoot, add Other Diagnostic Data (linked, App
   Functionality).
6. **Device ID?** No: the IP is not used to identify a device.

These answers assume the production zone retains nothing beyond Security Analytics.
Zone-level HTTP logging, Logpush or Instant Logs would retain IPs and headers if someone
configured them (open item 15).

**Rate limiting (#98).** Sign-in and token refresh allow 60 requests a minute per
client IP address (`CF-Connecting-IP`); session uploads allow 1,200 a minute per
account (`web/src/server/lib/rate-limit.ts`). Both use Cloudflare's Workers rate
limiting bindings with 60-second windows: Cloudflare's rate limiter counts per key for
one-minute windows. MadeGood's own code never writes the IP address to D1, R2 or its
logs. A refused request gets HTTP 429 with `Retry-After: 60`. No row of its own: the
limiter's counter is not readable by the developer, and the IP's retained copy is
already declared under Coarse Location above.

**Data shared publicly: none while sharing is unavailable** (item 17). Every session is
private and no account can turn sharing on. The rest of this paragraph and the next
describe sharing for when it returns. A new upload takes the account's **Visibility of new
sessions** setting (`users.default_visibility`, applied on insert in
`session-upload.ts`). That setting is Private unless the user changes it in the
website's Settings, where Unlisted or Public make future uploads shared without a
per-session step. The owner can also change one session's visibility. An unlisted or
public session's page shows its track (with privacy zones cut out), stats, title and
notes to anyone with the link, but not heart rate. This is user-initiated sharing, not
collection by a third party; the privacy policy explains it.

**Public profile (#95).** The profile is off by default. In website Settings, users
can enable it, enter a public display name and choose an optional URL username. The
URL uses a random ID. A chosen `@username` can appear before that ID.
The enabled profile lists public sessions and their totals. To others it is visible
only while the account has a public session. Its page, link metadata and
`GET /api/users/{profileKey}` can then show the chosen display name. Public session
pages and responses from `GET /api/sessions/{id}` include the profile link and chosen
name while the profile is enabled. Disabling the profile hides these details on
all surfaces. Each session keeps its own visibility.

**Account deletion (#135).** The deletion marker is committed before any purge. From
then on every public read requires an active owner: the session metadata and track
endpoints, the profile API, profile and session tags, the route image, and live voyage
shares. Each answers as if the resource didn't exist, even while rows and R2 objects are
still waiting for the purge or its retries.

**Route preview images (#96).** For an unlisted or public session, the Worker draws a
1200 × 630 PNG of the route with privacy zones cut out, plus the sport, distance and
duration, for link previews (`/s/<id>/og.png`, `web/src/server/lib/og-image.ts`). It
is rendered on request from the stored track and kept in Cloudflare's edge cache for up
to five minutes; nothing is written to D1 or R2. Private, deleted and unprocessed
sessions get the brand image. Chat apps and social sites that unfurl a link fetch the
image, as anyone with the link could. Nothing new is collected.

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
- **Voyage legs** (`VoyageRecorder`) are Debug-only for 1.0 (#138, item 12): Release
  has no Voyages tab and skips leg recovery at launch, so it never starts one.
- **The anchor alarm** (`AnchorWatch`), only while armed. It runs standard updates
  through `CLLocationManager` with `allowsBackgroundLocationUpdates` and
  `pausesLocationUpdatesAutomatically = false`, so fixes keep arriving while the boat
  lies still. Setup is foreground only, but it does use location: opening the Anchor
  Alarm screen (`AnchorWatch.beginSetup`) asks for When In Use permission if needed and
  starts foreground updates before anything is armed, to show the position and place the
  anchor point. Disarm invalidates the background session.
- **Man-overboard without a recording** (`ManOverboard`), while any mark still needs
  guidance or a press is waiting for its first fix, so a mark made during a countdown,
  a mirrored watch session or with nothing running keeps getting fixes when the phone
  locks. Clear removes only the current target; the next newest mark becomes the
  target, and background updates continue until the last mark is cleared. During a
  recording, MOB uses the recording's fixes.

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
> receiving location in the background until every mark is cleared, because the phone
> may be locked or pocketed during a recovery.

The drift detector needs a running app and usable GPS fixes: a fix counts only with a
reported accuracy of 25 m or better (`AnchorAlarm.maximumAccuracy`). A fix is outside
when its distance from the anchor, less the larger of its accuracy and 5 m, still
exceeds the radius, so the alarm needs the boat more than 5 m beyond the circle;
three such fixes confirm drift (`confirmationFixCount`). Uncertain fixes leave the
count as it is; only a confidently inside fix resets it. With a 10 m radius and
fixes at the 25 m limit, a fix counts as outside only beyond 35 m from the anchor. A pending GPS backup alarm ("Check anchor and GPS") asks
the operator to check the anchor and GPS if usable fixes near the swing circle stop
arriving for about two minutes (`AnchorGPSLoss.timeout`, renewed at most every 30 s).
It can fire while GPS still delivers updates, if those updates are too inaccurate to
use. Force-quitting stops drift monitoring until
the app is reopened. The pending GPS backup alarm can still sound. The user
controls the Alarms permission in Settings. Turning it off also disables Lock Screen
sound for subsequent warnings.

**AlarmKit.** The iPhone app has `NSAlarmKitUsageDescription` and asks for the Alarms
permission (`AlarmManager.requestAuthorization`) only when the user taps Arm anchor
alarm for the first time; it is not requested at launch. It schedules two kinds of
system alarm, both only while the anchor alarm is armed: the drift alarm, when three
confident fixes fall more than 5 m outside the swing radius with no confidently inside
fix between them, and the GPS
backup alarm, renewed while usable fixes near the circle arrive and left to sound about
two minutes after they stop. Stop on a sounding drift alarm snoozes it for two minutes
(`AnchorAlarm.snoozeDuration`) while the boat stays outside. Disarm cancels both. No other feature uses AlarmKit.

### Purpose strings

Checked against the code for this draft (items 6 and 9). They describe the Release
build: Voyages is hidden there (#138), so no string mentions voyage legs. The iPhone and watch share
the Health and motion strings; each app has its own location string. No Always,
Bluetooth, camera, photos, microphone, contacts, tracking or Local Network string is
needed: nothing uses those APIs.

| Key | App | String |
|---|---|---|
| `NSLocationWhenInUseUsageDescription` | iPhone | "MadeGood records your track, speed and course during a session, including with the screen off. It also uses your position for start-line pings, to mark a man-overboard position and guide you back to it, to set an anchor point and watch for drift while the anchor alarm is armed, and, rounded to about 11 km, for local conditions if you turn them on." |
| `NSLocationWhenInUseUsageDescription` | Watch | "MadeGood records your track, speed and course during a session, including with the screen off. It also uses your position for start-line pings, and to mark a man-overboard position and guide you back to it." |
| `NSAlarmKitUsageDescription` | iPhone | "MadeGood sounds an alarm if your boat drifts outside the swing radius you set, or if usable GPS positions stop arriving while the anchor alarm is armed." |
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
  sign-in at once: it can no longer sign in, read or write, and every public read
  (shared sessions, tracks, route images, the profile and its link tags, live shares)
  answers as for an unknown resource from that moment (#135). It then removes the D1 rows
  (sessions, privacy zones, voyages and legs) and every R2 object, retrying on the
  scheduled sweep until done (backoff from 1 minute, doubling to at most 512 minutes, 8 h 32 min, after
  ten consecutive failures, before a retry is eligible, then picked up by the 30-minute
  cron, 25 accounts per run; the
  policy therefore promises automatic retries, not an interval). The account record and
  deleted session IDs go last: no sooner than the 20-minute grace period
  (`DELETION_GRACE_MS`), and only once cleanup has succeeded and the pending-delete ledger
  is empty, so a failing step delays it (`web/src/server/lib/account-deletion.ts`). The response is 202. Afterwards the iPhone
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

Paste the quoted block into App Store Connect → App Review Information → Notes. It
describes a Release archive with sync configured (item 5) and Voyages hidden (item 12).
Attach the screen recording of a real session (item 14). App Store Connect allows 4,000 bytes;
as plain text (bold markers removed, one line per paragraph) the note is 3,886 UTF-8
bytes.

> MadeGood records sailing, windsurfing, kayak, canoe, SUP and motorboat sessions on
> iPhone and Apple Watch. It is not for navigation, and its speeds are personal
> records, not certified measurements. An account is optional: everything below except
> sync works without signing in.
>
> **Recording on land.** On iPhone, open Record, tap any sport and allow location.
> Walk or drive: speed, distance and the map update from GPS. Tap Stop, then open the
> session in History for the map, charts, laps, splits and replay. Sport metrics such
> as tacks, planing time or paddle strokes need real time on the water; the attached
> screen recording of a real session shows them.
>
> **Start line.** In Settings, open Sailing and set Countdown to 1 min. On the Record
> tab, tap Sailing to start the countdown. Tap one ping button, walk at least 15 m (the
> line must be at least 10 m long), then tap the other. Each ping needs a GPS fix
> accurate to 15 m, so do this outdoors with a clear sky. Distance to the line appears
> under the countdown once both ends are set. Time to burn and line bias need a real
> start (approaching the line from the pre-start side, and wind from sailing both
> tacks); the screen recording shows them.
>
> **Man-overboard.** The iPhone button is off by default: in Settings → Safety, turn on
> Show Man Overboard (MOB) Button. On the Record tab, touch and hold MOB for about half
> a second. The man-overboard screen shows distance and bearing back to the mark. Clear
> removes the current mark. If you made more than one, the next newest becomes the
> target, and location keeps running until the last one is cleared.
>
> **Anchor alarm (iPhone).** On the Record tab, tap Anchor alarm below the sport list
> (also on a live motorboat session). Opening it starts location; allow it, with Precise
> Location on. The anchor point is already your current position (tap the map to move
> it; Use current position then moves it back). Choose the smallest swing radius
> (10 m) and tap Arm anchor alarm, then allow Alarms. Lock the phone and walk at least
> 70 m away (60 m beyond the circle), outdoors, and wait. Drift needs three fixes, each
> accurate to 25 m, that put the phone more than the larger of its accuracy and 5 m
> beyond the circle; then a system alarm sounds on the Lock Screen. Stop silences it for
> two minutes; it sounds again if you are still outside. Disarm ends monitoring. If no
> usable fix arrives for about two minutes while armed (GPS stops, or its fixes are too
> inaccurate, even if updates continue), a GPS backup alarm, "Check anchor and GPS",
> sounds instead.
>
> **Why location runs in the background for hours.** Recording keeps running with the
> screen off because the phone is in a dry bag or pocket for the whole session. The
> anchor alarm is a boating safety aid: a boat can lie at anchor for hours, often
> overnight, and start to drag at any time, so drift has to be checked while the phone
> is locked. Man-overboard keeps receiving location until every mark is cleared. Each
> is started by the user, uses When In Use permission, shows the location indicator,
> and stops on Stop, Disarm or Clear. AlarmKit is used only by the anchor alarm, to
> sound the drift and GPS backup alarms on the Lock Screen.
>
> **Sign in, sync and account deletion.** In Settings → Account, tap Sign in with
> Apple. This creates the account (Apple's user ID and, if shared, your name) but
> uploads no sessions. Turn on **Sync sessions**. New uploads take the account's
> Visibility of new sessions, set on the website (Private for a new account). Sessions recorded more than
> ten minutes after signing in upload automatically. One recorded sooner, or before
> sign-in, waits: tap Upload Earlier Sessions. View it at https://madegood.app, signed
> in with the same Apple ID. Settings → Account → Delete Account deletes the account and
> everything uploaded after a confirmation; recordings on the device stay. The website's
> Settings page has the same action.

Not in the note, for the owner:

- The synthetic demo modes (`-demoSession`, `-demoOCS`, `-demoOffWater`) are Debug-only
  launch arguments (`DemoFeed.isEnabled` is `false` in Release), so App Review cannot
  use them. They are fine for screenshots, but the App Review attachment should be a
  screen recording of a real session on the Release build (item 14): tacks, a start
  with time to burn and line bias, planing or strokes.
- Time to burn shows only while the boat is on the pre-start side (right of the line
  looking from the pin to the boat end), moving at 0.3 m/s or more with a course that
  closes on the line, and within an hour of it (`StartLinePosition.timeToLine`). Line
  bias needs a pre-start wind estimate. Neither is reliable on land, so the walkthrough
  leaves them to the recording.
- The anchor walk: with a 10 m radius a fix counts as outside only beyond 10 m plus the
  larger of its accuracy and 5 m, so up to 35 m at the 25 m accuracy limit; 70 m leaves
  room for GPS error. The anchor point is fixed at the position when Arm is tapped
  unless the map was tapped, so arm where you start the walk.
- Sync eligibility widens each recording by ten minutes on both sides
  (`SessionSyncConsent.clockMargin`), so a recording that starts within ten minutes of
  sign-in is an earlier session that needs the explicit choice.
- Steps above match the UI at the time of writing (`AnchorAlarmView`, `ManOverboardViews`,
  `StartLinePanel`, `SessionSyncSection`). Walk through them on the submitted build.

## Listing

Final copy for App Store Connect. Counts are characters as App Store Connect counts them
(Unicode characters, including spaces and punctuation), checked with Python's `len`.

| Field | Limit | Count | Text |
|---|---|---|---|
| Name | 30 | 30 | MadeGood: Sail & Kayak Tracker |
| Subtitle | 30 | 30 | Windsurf, SUP, Canoe & Boating |
| Promotional text | 170 | 154 | Record sailing, windsurfing, paddling and motorboat sessions on Apple Watch and iPhone. No account needed, and sessions are private unless you share them. |
| Keywords | 100 | 98 | `paddle,paddleboard,dinghy,regatta,race,GPS,speed,speedsurf,anchor,motorboat,tack,gybe,VMG,nautical` |
| Support URL | — | — | https://madegood.app/support (item 11) |
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
- **Description:** 3,060 of 4,000 characters. It claims only what this build does,
  says "Not for navigation", says the account is optional, and leaves out Voyages.

```text
MadeGood records your time on the water with Apple Watch, iPhone, or both. Start a session, put the phone in a dry bag or the watch on your wrist, and review your track, speed and sport-specific numbers afterwards. You don't need an account: sessions are recorded and stored on your devices.

SAILING
• Tacks and gybes, a wind direction estimate, and VMG upwind and downwind
• Start countdown with a start line: ping the pin and the boat end, then see distance to the line, time to burn, line bias and an OCS warning at the gun
• Compare a session's wind estimate with modelled wind from Apple Weather

WINDSURFING
• Speedsurfing bests: 2 s, 10 s, 5×10 s, 500 m, nautical mile and alpha 500
• Planing time against a threshold you set, and estimated gybes

KAYAK, CANOE AND SUP
• Stroke rate, stroke count and distance per stroke
• Stroke intervals of 100 strokes in replay, to compare one part of a paddle with another

MOTORBOATING
• Trip log in nautical miles, engine time and a fuel estimate
• Anchor alarm on iPhone: arm it at your anchor point with a swing radius, and the iPhone sounds a system alarm if the boat drifts outside it, or if usable GPS positions stop arriving

ON APPLE WATCH
• Start from your wrist and see live speed, distance and heart rate with your heart-rate zone
• Mark a man-overboard position and get a bearing and distance back to it
• Lock the screen against spray
• The watch records on its own and hands the session to your iPhone

ON IPHONE
• Record with the screen off, with a Live Activity on the Lock Screen
• Man-overboard: touch and hold to mark a position, then steer back with distance and bearing
• Optional local conditions on the start screen, from Apple Weather
• Review each session with a speed-colored map, charts, laps, 1 km splits, time in heart-rate zones and replay; trim the start or end
• Export any session as GPX

APPLE HEALTH
Save sessions to Apple Health as workouts with the route and heart rate. You choose per sport.

OPTIONAL ACCOUNT
Sign in with Apple and turn on Sync sessions to upload them to madegood.app, where you can browse, replay and share them. Uploads are private unless you share them, one by one or with a default you set. An unlisted session is visible to anyone with its link; a public one appears on your public profile if you enable it in website Settings. Privacy zones cut places you choose, like home, out of shared tracks. Shared links preview with a route image. You can export everything in your account and delete the account from the app or the website.

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
- **Screenshots:** `scripts/app-store-screenshots` (after generating the Xcode project)
  runs the `PhoneAppStoreScreenshots` and `WatchAppStoreScreenshots` UI test classes on
  its own iPhone 18 Pro Max and Apple Watch Ultra 4 (49mm) simulators, with the status
  bar set to 9:41, full battery and signal, and light appearance (watchOS simulators
  allow no status bar override, so the watch clock shows the time of the run). It writes
  `build/app-store-screenshots/iphone-6.9/NN-name.png` at 1320 × 2868 (iPhone with
  Dynamic Island, large display) and `build/app-store-screenshots/watch-ultra/NN-name.png`
  at 422 × 514 (Apple Watch Ultra 4 and 3), and fails if a shot is missing, the wrong
  size or has an alpha channel. `--device iphone` or `--device watch` captures one set.
  The shots use the synthetic demo data (`-demoSession`, `-demoHistory`, canned weather),
  never a real session; the folder is gitignored, so upload the PNGs by hand. Check App
  Store Connect's current list of required sizes before submitting.
