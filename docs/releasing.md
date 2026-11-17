# Releasing the apps to TestFlight

The iPhone app, with the watch app and widget extensions inside it, goes to TestFlight
from GitHub Actions ([`testflight.yml`](../.github/workflows/testflight.yml)). It uses
`xcodebuild` and automatic signing with an App Store Connect API key, so there are no
certificates, profiles or fastlane setup to maintain.

## Shipping a build

- **Any time:** Actions → TestFlight → Run workflow (needs write access).
- **A version:** bump `MARKETING_VERSION` in `apps/apple/Config/MadeGood.xcconfig`, merge,
  then push a matching tag, for example `git tag v0.2.0 && git push origin v0.2.0`.

The build number is the UTC time of the build (`20261117.91530` for 09:15:30), so it
always increases, even when an older run is re-run. Apple processes an upload in about 10–30 minutes; the **Internal** TestFlight
group has automatic distribution on, so its testers get the build without further
steps.

## One-time setup (for a fork or a new team)

1. In Certificates, Identifiers & Profiles, register explicit App IDs for
   `<prefix>`, `<prefix>.watchkitapp`, `<prefix>.widgets` and
   `<prefix>.watchkitapp.complications`. Enable HealthKit on the first two and Sign in
   with Apple on the first.
2. In App Store Connect, create the iOS app with bundle ID `<prefix>` and an internal
   TestFlight group.
3. In Users and Access → Integrations → App Store Connect API, generate a team key with
   the **Admin** role and download the `.p8` (Apple allows one download). Admin is
   required: Xcode signs with a cloud-managed distribution certificate, and App Store
   Connect refuses that to App Manager keys ("Cloud signing permission error"). Keep the
   key only in repository secrets, and revoke it if it might have leaked.
4. Add these repository secrets:

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | Team ID (developer.apple.com → Membership) |
   | `APP_STORE_CONNECT_KEY_ID` | The key's ID |
   | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID shown above the keys |
   | `APP_STORE_CONNECT_API_KEY` | Contents of the `.p8`: `gh secret set APP_STORE_CONNECT_API_KEY < AuthKey_XXXX.p8` |

   A fork with its own prefix also sets `BUNDLE_ID_PREFIX` (see
   `apps/apple/Config/Local.xcconfig.example`); the workflow would need it passed as a
   build setting.

Keep the `.p8` in a password manager or `~/.appstoreconnect/private_keys/`, never in the
repository.

## Building locally

The same script runs on a Mac. After `tuist install && tuist generate --no-open` in
`apps/apple`:

```sh
APPLE_TEAM_ID=… APP_STORE_CONNECT_KEY_ID=… APP_STORE_CONNECT_ISSUER_ID=… \
APP_STORE_CONNECT_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_….p8 \
BUILD_NUMBER=0.1 UPLOAD=0 scripts/testflight
```

`UPLOAD=0` exports a signed `.ipa` without uploading. Leave it out to upload, and use a
build number higher than any already in App Store Connect.
