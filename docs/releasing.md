# Releasing the apps to TestFlight

The iPhone app, with the watch app and widget extensions inside it, goes to TestFlight
from GitHub Actions ([`testflight.yml`](../.github/workflows/testflight.yml)). It uses
`xcodebuild` and automatic signing with an App Store Connect API key, so there are no
certificates, profiles or fastlane setup to maintain.

## Shipping a build

- **Any time:** Actions → TestFlight → Run workflow (needs write access).
- **A new minor or major version:** change `MARKETING_VERSION` in
  `apps/apple/Config/MadeGood.xcconfig` (for example to `0.2.0`), merge, then run the
  workflow or push a matching tag (`git tag v0.2.0 && git push origin v0.2.0`).

Every build gets a new version and build number without a commit:

- **Version** (`CFBundleShortVersionString`): the major.minor from the xcconfig plus the
  number of commits on the built branch, for example `0.1.39`. Main only gains commits,
  so each merge ships a higher version; running the workflow twice on the same commit
  gives the same version with a newer build number. Run it from `main`: another branch
  has a different count and can produce a version that is out of order.
- **Build number** (`CFBundleVersion`): the UTC time of the build (`20261117.91530` for
  09:15:30), so it always increases, even when an older run is re-run.

Apple processes an upload in about 10–30 minutes; the **Internal** TestFlight
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
BUILD_NUMBER="$(date -u +%Y%m%d).$((10#$(date -u +%H%M%S)))" UPLOAD=0 scripts/testflight
```

`UPLOAD=0` exports a signed `.ipa` without uploading. Leave it out to upload, and use a
build number higher than any already in App Store Connect. Set `MARKETING_VERSION` to
override the computed version.
