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
| 1 | **No in-app account deletion.** The API has `DELETE /api/me`, but neither the iPhone app (Settings → Account offers only Sign Out) nor the website calls it. | Guideline 5.1.1(v): an app that lets people create an account must let them start deleting it in the app. |
| 2 | **Sign in with Apple tokens are not revoked on deletion.** The Worker verifies identity tokens but never calls Apple's token revocation endpoint. | Apple asks apps using Sign in with Apple to revoke tokens when an account is deleted. Revoking needs a Sign in with Apple private key held as a Worker secret. |
| 3 | **No privacy policy.** There is no privacy policy page or URL. | Required in App Store Connect for every app, and for HealthKit apps in particular. The website could serve one at `/privacy`. |
| 4 | **No privacy manifest** (`PrivacyInfo.xcprivacy`). The app uses `UserDefaults` (settings and sync state) and file APIs. | Apps that use required-reason APIs must declare a reason in a privacy manifest. |
| 5 | **TestFlight builds have no sync.** `MADEGOOD_API_URL` is empty in `apps/apple/Config/MadeGood.xcconfig`, and CI has no `Local.xcconfig`. | Reviewers would see "Account sync isn't set up in this build." The label answers below assume sync is on; if it ships off, most of the "collected" rows go away. |
| 6 | **Health permission strings.** `NSHealthUpdateUsageDescription` says the app "runs a workout session" but not that it saves workouts, routes and heart rate to Health. `NSMotionUsageDescription` mentions detecting maneuvers, which use GPS, not motion. | Reviewers check that purpose strings describe what the app actually does (5.1.1(i)). Suggested wording is in [HealthKit](#healthkit). |
| 7 | ~~No full data export.~~ Done: `GET /api/me/export` (website Settings → Export all my data) and iPhone Settings → Your Data → Export All Recordings. | Not an App Store requirement; the privacy policy can now describe it. |

## Privacy nutrition label

**Tracking: No.** The app contains no third-party SDKs, analytics, advertising or
crash reporting, and links no data with other companies' data for advertising. No
`NSUserTrackingUsageDescription`, no IDFA.

**Without an account** (the default), nothing leaves the device except an optional
Open-Meteo request (below) and what the user chooses to send to Apple Health or to
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
| Identifiers | User ID | Yes | Yes | No | App Functionality | Apple's stable user identifier (`apple_sub`), the account ID and handle |
| Contact Info | Name | Yes, optional | Yes | No | App Functionality | The display name Apple shares on first sign-in, if the user allows it. Email is not requested (`requestedScopes = [.fullName]`) |
| Diagnostics | — | No | — | — | — | No crash or analytics SDK. Cloudflare request logs (Workers observability) hold IP addresses and URLs for the account owner; confirm whether to declare them or turn observability off |

Not collected: email, phone, contacts, photos, browsing or search history, purchases,
financial info, sensitive info, device ID, advertising data, audio, raw wrist motion
(the 100 Hz motion stream never leaves the phone unless the user shares a raw recording
file themselves).

**Open-Meteo.** Only when the user taps "Compare with Open-Meteo" in a sailing
session's detail, the phone sends Open-Meteo the selection's mean position rounded to
0.5° (about 50 km) and its UTC start and end dates, with no account, key, cookies or
identifiers (docs/metrics.md). It answers the request in real time and is not linked to
the user. Proposed: not declared as collected (it is not retained for the developer),
but described in the privacy policy. Confirm.

**Local conditions.** Off until the user taps Show on the start screen (or turns on
Settings > Weather > Local Conditions). Then, while the start screen is open and at
most every 15 minutes, the phone sends Open-Meteo's forecast API its position rounded
to 0.1° (about 10 km), again with no account, key, cookies or identifiers. The
position is not stored; the last answer is kept on the phone. It uses the existing
When In Use location permission, whose iPhone prompt now mentions local conditions.

**Data shared publicly.** A session is private by default. The owner can make it
unlisted or public; then the website shows its track (with privacy zones cut out),
stats and title to anyone with the link. This is user-initiated sharing, not
collection by a third party, but the privacy policy should explain it.

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
> and in the session summary, and, if the user keeps "Save to Health" on for that
> sport, saves the session to Health as a workout with its route. Motorboating is not
> saved to Health unless the user turns it on. Health data is not used for advertising
> and is not shared with third parties. If the user signs in and turns on sync, heart
> rate recorded in a session is uploaded with that session to their private MadeGood
> account so they can view it on the website; it is deleted with the session or the
> account.

Suggested purpose strings (item 6):

- `NSHealthShareUsageDescription`: "MadeGood reads your heart rate during a session to
  show it live and in your session summary."
- `NSHealthUpdateUsageDescription`: "MadeGood saves your sessions to Health as
  workouts, with the route and heart rate, if you turn on Save to Health."

## Background location

The iPhone app declares `UIBackgroundModes: location` and asks only for **When In Use**
authorization (`NSLocationWhenInUseUsageDescription`). While a session or a Voyage leg
is recording it holds a `CLBackgroundActivitySession`, which keeps When In Use location
running with the screen off and shows the system location indicator. It never asks for
Always and never uses significant-change, region monitoring or visits. Location stops
when recording ends. The watch app uses the `workout-processing` background mode
during its workout session instead.

Draft justification for App Review:

> MadeGood records a GPS track of a session on the water. Users put the iPhone in a dry
> bag, a pocket or a mount and turn the screen off, often for hours: a motorboat trip, a
> sailing race, a long paddle. Recording must continue in the background for the track,
> distance and speed to be correct. Location is used only while the user is recording
> (they start and stop it explicitly), only with When In Use permission, and the system
> shows the location indicator throughout. On Apple Watch, recording runs inside a
> HealthKit workout session. Motorboat sessions are usually recorded on the iPhone
> alone, without a watch.

**Anchor alarm.** PLAN §5 and §11 plan an anchor alarm (alert when the boat drifts
outside a radius, running in the background for hours), which is a recognized safety
use. It is **not built yet**. Leave it out of the justification and the App Store
description until it ships; when it does, add a paragraph describing the user-started
alarm, its notification, and that it still uses When In Use with a background activity
session.

## Account and deletion

- An account is optional. Everything works offline without one; Sign in with Apple is
  the only sign-in method, on the iPhone (Settings → Account) and the website.
- **Deletion today:** `DELETE /api/me` deletes the user's D1 rows (sessions, refresh
  tokens, privacy zones, cascading from the user) and every R2 object under their
  prefix. Sessions on the device are kept (they were never only in the account).
- **Needed** (item 1): a "Delete Account" button in iPhone Settings → Account, and on the
  website's settings page, each with a confirmation that says what is deleted; sign out
  afterwards. Item 2 adds Apple token revocation.
- Draft text for the confirmation: "Delete your MadeGood account? This deletes every
  session you have uploaded, your privacy zones and your sign-in from MadeGood's
  servers. Sessions on this iPhone and workouts in Apple Health are not affected. This
  can't be undone."

## Export

- **Per session (iPhone):** session detail → Export GPX (GPX 1.1 track), and Share raw
  recording (the raw NDJSON folder, zipped). The detail screen warns that exports
  contain precise locations and times.
- **Apple Health:** saved workouts and routes are exportable through Health.
- **Files app:** recordings live in the app's Documents folder, visible in Files
  (`UIFileSharingEnabled`).
- **All recordings (iPhone):** Settings → Your Data → Export All Recordings zips every
  recording folder on the phone and opens the share sheet. Export files are deleted when
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

> MadeGood needs to be on the water to record real data. To see a session without
> going outside, start any sport on the iPhone (Record tab) and walk or drive: speed
> and distance update from GPS. Session detail, History and Settings work with any
> recorded session. An account is optional; sign in with Apple under Settings → Account
> to try sync, and visit <host> to see the session on the web. MadeGood is not for
> navigation, and its speeds are personal records, not certified measurements.

Consider attaching a short screen recording of a real session, since reviewers cannot
test sport metrics such as tacks or stroke rate.

## Listing

- **Name:** "MadeGood: Sail & Kayak Tracker" (PLAN, 30 characters maximum).
- **Category:** Sports (primary), Health & Fitness (secondary). Confirm.
- **Age rating:** 4+ (no objectionable content; no unrestricted web access; no
  user-to-user communication).
- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` is set (HTTPS only).
- **Screenshots:** the CI UI tests export screenshots of the synthetic `-demoSession`
  data (`xcrun xcresulttool export attachments`). They are 1206 × 2622 (a 6.3-inch
  iPhone); App Store Connect requires its current largest iPhone size, so run the UI
  tests on that simulator for the submission set, and add Apple Watch screenshots.
  Use demo data only, never a real session.
- **Description:** keep claims to what ships (see the website landing page), say "not
  for navigation", and leave out Voyages features that are not released.
