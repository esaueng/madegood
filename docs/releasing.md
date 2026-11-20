# Releasing the apps to TestFlight

The iPhone app, with the watch app and widget extensions inside it, goes to TestFlight
from GitHub Actions ([`testflight.yml`](../.github/workflows/testflight.yml)). It uses
`xcodebuild` and automatic signing with an App Store Connect API key, so there are no
profiles or fastlane setup to maintain. The one certificate it needs is a long-lived Apple
Development identity stored as a secret (step 5 below).

## Shipping a build

- **Any time:** Actions → TestFlight → Run workflow (needs write access).
- **A new minor or major version:** change `MARKETING_VERSION` in
  `apps/apple/Config/MadeGood.xcconfig` (for example to `0.2.0`), merge, then run the
  workflow or push a matching tag (`git tag v0.2.0 && git push origin v0.2.0`).

Every build gets a new version and build number without a commit:

- **Version** (`CFBundleShortVersionString`): the major.minor from the xcconfig plus the
  number of commits on the built branch, for example `0.1.39`. Main only gains commits,
  so each merge ships a higher version; running the workflow twice on the same commit
  gives the same version with a newer build number. The workflow uploads only main's
  current tip, and stops otherwise: another branch, or a re-run of an older run, would
  ship a lower version than one already uploaded. A tag must point at that tip too.
- **Build number** (`CFBundleVersion`): the UTC time of the build (`20261117.91530` for
  09:15:30), so it always increases, even when an older run is re-run.

Apple processes an upload in about 10–30 minutes; the **Internal** TestFlight
group has automatic distribution on, so its testers get the build without further
steps.

Session sync: the workflow passes the repository secret `MADEGOOD_API_URL` (Settings →
Secrets and variables → Actions → Secrets, for example `https://<your-worker>/api`) into the
build. It is a secret rather than a variable so the log masks it (the host names your Workers
subdomain), and failure logs redact it before upload. Without it, TestFlight builds show sync as not set up.

## Voyages for 1.0

`MADEGOOD_VOYAGES` is a Swift compilation condition set in the Debug configuration in
[`apps/apple/Project.swift`](../apps/apple/Project.swift). Release keeps the Voyages tab
and its settings hidden and skips voyage recording recovery, sync, and live sharing.
Existing voyage legs, including interrupted recordings, stay on disk.

When Phase 5 ships, add `MADEGOOD_VOYAGES` to the Release configuration's
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` alongside `$(inherited)` and regenerate the
Xcode project with `tuist generate --no-open`. Update the Release expectations in
`PhoneVoyagesAvailabilityUITests` and `VoyageLaunchDelegateTests` when enabling it.

## Publish the landing page download link

1. Open the Cloudflare dashboard and go to **Workers & Pages** → **madegood** →
   **Settings** → **Variables and Secrets**. For a self-hosted site, select its Worker.
2. Add a **Text** variable named `DOWNLOAD_URL` and paste the public TestFlight invite
   URL from `https://testflight.apple.com`. Select **Deploy** to apply the binding.
3. Reload the landing page and check that both buttons read **Join the TestFlight beta**
   and open the invite. When the app is live in the App Store, replace the value with
   its `https://apps.apple.com` product URL, select **Deploy**, and check that both
   buttons read **Download on the App Store**.

Cloudflare deploys a new Worker version with the updated binding using the existing build.
Wrangler preserves this dashboard setting on later deployments. Remove the variable or
clear its value and select **Deploy** to restore the coming-soon text. The website only
accepts HTTPS links to the two Apple hosts above. Wrangler also retains other deployed
text and JSON variables when a key is removed from `vars`. To retire one, remove it from
both `vars` and the dashboard. To turn off web sign-in, set `APPLE_WEB_CLIENT_ID` to an
empty string in `vars`.

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

5. Store one Apple Development identity for archiving. Each runner starts with an empty
   keychain, and without an identity automatic signing creates a new Apple Development
   certificate on every run, until the account reaches Apple's limit and archiving fails
   ("Your account has reached the maximum number of certificates"). Create the certificate
   once (Xcode → Settings → Accounts → Manage Certificates → + → Apple Development, or
   from a CSR in Certificates, Identifiers & Profiles), export it with its private key as
   a `.p12` with a password, then:

   ```sh
   base64 -i signing.p12 | gh secret set APPLE_SIGNING_P12
   gh secret set APPLE_SIGNING_P12_PASSWORD
   ```

   The workflow imports it into a throwaway keychain and deletes that keychain after the
   run; the export step still signs with the cloud-managed distribution certificate. The
   certificate expires after a year: make a new one, update both secrets, and revoke the
   old certificate. If runs already filled the account, revoke the extra Apple Development
   certificates named "Created via API" first.

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
