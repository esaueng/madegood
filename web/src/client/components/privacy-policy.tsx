import { Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

const GITHUB_URL = "https://github.com/esaueng/madegood";
const ISSUES_URL = `${GITHUB_URL}/issues`;
// The policy moved from the route file into this component in November 2026; the two
// histories together hold every published version.
export const HISTORY_URL = `${GITHUB_URL}/commits/main/web/src/client/components/privacy-policy.tsx`;
export const EARLIER_HISTORY_URL = `${GITHUB_URL}/commits/main/web/src/client/routes/privacy.tsx`;

// Plain-language privacy policy. Keep it in step with what the code does: docs/app-store.md
// lists the data each part of the app sends, and the App Store privacy label must match.

const link = "underline underline-offset-2";

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section aria-labelledby={id} className="grid gap-3">
      <h2 id={id} className="text-xl font-semibold tracking-tight">
        {title}
      </h2>
      {children}
    </section>
  );
}

export function PrivacyPolicy() {
  return (
    <article className="mx-auto grid max-w-prose gap-10 py-10 leading-relaxed [&_li]:mt-1.5 [&_ul]:list-disc [&_ul]:pl-5">
      <header className="grid gap-3">
        <h1 className="text-3xl font-bold tracking-tight">Privacy policy</h1>
        <p className="text-lg text-muted-foreground">
          MadeGood records your time on the water for you. It has no ads, no analytics and no
          tracking, and it does not sell or share your data. You can use the apps without an
          account; then your sessions never leave your devices unless you send them somewhere.
        </p>
        <p className="text-sm text-muted-foreground">
          This policy covers the MadeGood iPhone and Apple Watch apps and this website, run by the
          MadeGood maintainers. MadeGood is open source: if you use a copy of the server that
          someone else runs, their policy applies to it.
        </p>
      </header>

      <Section id="on-device" title="On your iPhone and Apple Watch">
        <p>The apps use:</p>
        <ul>
          <li>
            <strong>Location</strong>, while you are recording, to measure your track, speed and
            course. The iPhone keeps recording with the screen off and shows the system location
            indicator. Location is also used to ping the ends of a race start line during a
            countdown, and to mark a man-overboard position and guide you back to it; on the iPhone,
            man-overboard marks keep receiving location with the screen locked until you clear the
            last one. If you turn on local conditions, the iPhone also reads its position while the
            start screen is open (below).
          </li>
          <li>
            <strong>The anchor alarm</strong> on the iPhone. Opening the Anchor Alarm screen starts
            location while the screen is open, before you arm anything (and asks for permission if
            you haven't given it), to show your position and place the anchor point. Once you arm
            it, it reads your location in the background, with the screen locked and for as long as
            it stays armed (often hours), and shows the system location indicator. It compares each
            position with the anchor point and swing radius you chose, on the iPhone. With your
            permission for Alarms, it schedules system alarms that sound if the boat drifts outside
            the circle, or if usable GPS positions stop arriving for about two minutes: GPS has
            stopped, or the positions it still sends are too inaccurate to use. The anchor point,
            the radius and these positions stay on the iPhone and are not uploaded, even with an
            account. Disarming stops background location for the alarm and removes the saved anchor
            point.
          </li>
          <li>
            <strong>Motion</strong> sensors during a session, to count paddle strokes. The samples
            are kept in the recording on your devices.
          </li>
          <li>
            <strong>Apple Health</strong>, with your permission: heart rate during a session, shown
            live and as time in heart-rate zones (worked out on your devices from a maximum heart
            rate you set), and saving the session to Health as a workout with its route, for the
            sports where you turn on Save to Health.
          </li>
        </ul>
        <p>
          Recordings are stored in the app on your devices; the watch hands its recordings to your
          iPhone. Settings are stored on the device and kept in step between your watch and iPhone.
          Maps in the apps are Apple Maps, which loads map images from Apple for the area on screen.
        </p>
        <p>
          The apps send nothing to MadeGood until you try to sign in (see below). Without an
          account, only these leave your devices, and they go to Apple or to wherever you send them:
        </p>
        <ul>
          <li>
            <strong>Apple Weather</strong> (Apple's WeatherKit), for local conditions if you turn
            them on (Show on the start screen, or Settings → Weather), and for a sailing session's
            wind when you tap “Compare with Apple Weather”. The iPhone rounds your position to a
            0.1° grid square (about 11 km across) and sends Apple only that square, plus the
            session's hours for a comparison, never your exact position. While the start screen is
            open, local conditions refresh automatically every 15 minutes; turning them on or
            refreshing by hand fetches them at once. Answers are kept only on the iPhone, in a small
            cache that iOS can clear at any time. The app reuses current conditions for up to 15
            minutes, forecast wind for up to 1 hour and past wind for up to 24 hours. After that an
            answer is no longer used, but it stays in the cache until the app's cleanup removes it,
            which runs when the app starts and each time it returns to the foreground, or until iOS
            clears the cache. Older versions of the app kept these answers in its settings; updating
            the app removes them. MadeGood's server never sees these requests. Apple says this
            location is used only to provide weather forecasts, is not associated with personally
            identifiable information and is not tracked between requests; see{" "}
            <a href="https://developer.apple.com/weatherkit/" className={link}>
              WeatherKit
            </a>{" "}
            and Apple's privacy policy.
          </li>
          <li>
            Files you choose to share or export (GPX, raw recordings, ZIP files). They contain
            precise positions and times. A raw recording also holds the motion samples and, if
            recorded, heart rate; its times are clock times, and a recording made by an older
            version of the app is converted to that format when you share or export it, one at a
            time or all together.
          </li>
        </ul>
      </Section>

      <Section id="account" title="If you sign in and sync">
        <p>
          An account is optional. You sign in with Apple; MadeGood asks Apple for your name only,
          never your email address, and you can choose not to share it.
        </p>
        <p>
          <strong>Signing in.</strong> When you complete Sign in with Apple, the iPhone app or this
          website sends MadeGood's server, through Cloudflare, the signed confirmation Apple returns
          (it carries Apple's identifier for you) and your name if you shared it. This request is
          sent on your first sign-in, before any account exists, and also when signing in then
          fails. Cloudflare handles your IP address for it as for any request (see Where it runs).
          If the attempt is refused first because the confirmation is not valid or there were too
          many attempts, MadeGood stores nothing from it. If your account is still being deleted,
          the attempt is refused and stores nothing new, though it may retry finishing the deletion
          and note when to try again. Once the confirmation is checked, the server creates your
          account, or opens your existing one, and stores the following even if you never turn on
          sync: Apple's identifier for you, an account ID, a handle the server picks, your name if
          you shared it, when the account was created, and your settings (units, and Visibility of
          new sessions, which starts at Private). Only then does it issue the sign-in, storing a
          hash of its refresh token with its issue and expiry times (60 days) and whether it is for
          the app or the website. So a sign-in that fails at that last step can still leave the
          account record, and possibly the token hash, on the server. MadeGood does not remove such
          a record on its own: it stays until you delete the account, which you can do after signing
          in again. No session is uploaded.
        </p>
        <p>
          <strong>Syncing.</strong> Only when you also turn on <strong>Sync sessions</strong> (off
          after every new sign-in) does the iPhone upload the sessions you record while signed in
          (earlier ones only if you choose), with your account's Visibility of new sessions (see
          Sharing). The server holds the identifiers, settings and sign-in tokens below from
          sign-in, and the rest once sessions upload:
        </p>
        <ul>
          <li>
            <strong>Identifiers:</strong> Apple's identifier for your sign-in, an account ID, an
            account handle and your name if you shared it. The public profile has a random link when
            you enable it. You can choose a custom URL username and edit the name on your profile in
            Settings (see Sharing).
          </li>
          <li>
            <strong>Sessions:</strong> sport, times, distance, speeds, laps and other statistics,
            title and notes, visibility, and the track file: your GPS positions and, if recorded,
            heart rate.
          </li>
          <li>
            <strong>Settings:</strong> units, the default visibility of new sessions, and your
            public profile settings.
          </li>
          <li>
            <strong>Sign-in tokens</strong>, stored as hashes, so the apps and this website stay
            signed in. MadeGood holds no tokens from Apple.
          </li>
          <li>
            <strong>Data worked out from each track</strong> after it is uploaded: the area it
            covers (a bounding box), a coarse start location (geohash), the times of the first and
            last position, and for shared sessions a second bounding box and times with your privacy
            zones cut out. Only you see the first set; others see only the version with your zones
            cut out.
          </li>
          <li>
            <strong>Deleted session IDs:</strong> when you delete a session, its ID and the time are
            kept so a device that still has the recording cannot upload it again. They are removed
            with your account.
          </li>
        </ul>
        <p>
          <strong>Privacy zones</strong> are saved to your account whenever you add one on this
          website's Settings page, whether or not Sync sessions is on and even if you never use the
          iPhone app. Each is a precise position, the center you pick on the map or with “Use my
          location”, and a radius. They are deleted when you remove them or delete your account.
        </p>
        <p>
          <strong>Wind for shared sessions.</strong> When someone views an unlisted or public
          session on this website, the server asks Apple Weather (WeatherKit) for the hourly wind
          during it, and the page shows it with Apple Weather's attribution. The request uses only
          what others can see of the track, with your privacy zones cut out: one position, the
          center of that visible area, rounded to 0.1° (about 11 km), and the time range the visible
          part spans. No account, session ID or track is sent, and the request comes from MadeGood's
          server on Cloudflare, so Apple never sees your IP address or the viewer's for it. Private
          sessions never cause a request, and neither does a shared session whose whole track lies
          inside your privacy zones. The answer is kept only temporarily, for up to 3 hours, in
          Cloudflare's cache, under the rounded square and hours alone. It is not stored with the
          session or in the database, and data exports do not include it. Apple describes how it
          handles WeatherKit locations on the{" "}
          <a href="https://developer.apple.com/weatherkit/" className={link}>
            WeatherKit
          </a>{" "}
          page.
        </p>
        <p>
          The raw motion data the watch records stays on your devices. Your data is used only to
          show you your sessions, sync them and share what you choose to share.
        </p>
      </Section>

      <Section id="voyages" title="Voyages">
        <p>
          Voyages (multi-day passages made of legs) are being built and are{" "}
          <strong>not available</strong> in the released apps or on this service yet. When they are,
          this is what they will hold:
        </p>
        <ul>
          <li>
            <strong>Private voyage sync</strong>, only for a leg you choose to sync: the voyage's
            title, boat name and times, each leg's names, times and distance, and the leg's track
            file (GPS positions). Only you can see them. They are deleted with your account.
          </li>
          <li>
            <strong>Live voyage sharing</strong>, only while you share a voyage: its recent
            positions (at most 10,000), kept in a Cloudflare Durable Object. Anyone with the live
            link can follow the boat, delayed by up to a day if you choose and with your privacy
            zones hidden; the link expires after at most 7 days. Pausing hides the position at once,
            and stopping (or starting a new link) deletes the stored positions. A link that expires
            without being stopped has its positions deleted when it expires. Deleting your account
            deletes them too.
          </li>
        </ul>
      </Section>

      <Section id="sharing" title="Sharing">
        <p>
          <strong>Sharing is unavailable for now.</strong> Every session is private: only you can
          see it, on this website and in the iPhone app. Nothing can be made unlisted or public, and
          public profiles cannot be enabled. When sharing was switched off, every unlisted or public
          session became private and every public profile was turned off, so their links and
          previews stopped working for others. The rest of this section describes how sharing works
          when it is available.
        </p>
        <p>
          A new upload takes your account's <strong>Visibility of new sessions</strong> setting,
          which is Private unless you change it in{" "}
          <Link to="/settings" className={link}>
            Settings
          </Link>
          . If you set it to Unlisted or Public, sessions you upload afterwards are shared without
          any further step. You can also change each session's visibility. An <em>unlisted</em>{" "}
          session can be seen by anyone with its link; a <em>public</em> session by anyone. Others
          see its track, statistics, title and notes, but not your heart rate, and parts of the
          track inside your privacy zones are cut out.
        </p>
        <ul>
          <li>
            <strong>Public profile.</strong> Profiles start off. Enable yours in Settings to show
            the display name you enter for the profile, your totals and your public sessions once
            you have at least one public session. The link uses a random ID by default. If you
            choose a custom URL username, that username appears in the link. Anyone can also get the
            enabled profile's display name and public session data from the public profile API (
            <code>/api/users/</code> and the profile's URL identifier). Turning off your profile
            hides its page, public API data and personalized link preview. Public session pages and
            the public session API (<code>/api/sessions/</code> and the session ID) link to an
            enabled profile and show its chosen name if present. Private and unlisted sessions omit
            the profile, as do all session link previews. Each session keeps its own visibility.
          </li>
          <li>
            <strong>Link previews.</strong> When an unlisted or public session's link is posted in a
            chat app or on a social site, that service fetches a preview: the session's title,
            sport, distance, duration and top speed, and an image of the route with your privacy
            zones cut out. The server draws the image when it is requested and keeps it in
            Cloudflare's cache for at most five minutes; it is not stored with your data. Private
            sessions get a generic MadeGood image. An enabled public profile link previews with your
            display name, number of public sessions and their total distance. Search engines may
            index public sessions and your profile; unlisted sessions ask them not to.
          </li>
          <li>
            <strong>Turning sharing off.</strong> Settings, on this website and in the iPhone app,
            lists every session others can see and lets you make each one private. Turning off{" "}
            <em>Allow sharing</em> makes every session private at once: their links, previews and
            your profile stop working for others, and nothing can be shared again until you turn it
            back on. Copies that others already saved, and previews a chat app or search engine
            already fetched, are outside MadeGood's control.
          </li>
        </ul>
      </Section>

      <Section id="website" title="This website">
        <ul>
          <li>
            <strong>Cookies:</strong> only the ones that keep you signed in, plus a short-lived one
            while Sign in with Apple is in progress. No analytics or advertising cookies.
          </li>
          <li>
            <strong>Maps</strong> on session pages load from{" "}
            <a href="https://www.openstreetmap.org" className={link}>
              OpenStreetMap
            </a>{" "}
            and{" "}
            <a href="https://www.openseamap.org" className={link}>
              OpenSeaMap
            </a>
            . Your browser requests the map images for the area you look at directly from them, so
            they see your IP address and that area.
          </li>
          <li>
            “Use my location” on the Settings page asks your browser for your position only to place
            a privacy zone, and only when you click it. Saving the zone stores that position with
            your account (see Privacy zones above).
          </li>
        </ul>
      </Section>

      <Section id="hosting" title="Where it runs">
        <p>
          The server and this website run on Cloudflare (Workers, D1, R2, Queues and Durable
          Objects), MadeGood's hosting provider, which processes this data for MadeGood. Apart from
          Cloudflare and the Apple Weather request above, MadeGood uses no other services and gives
          your data to no one else.
        </p>
        <p>
          <strong>IP addresses and security records.</strong> Cloudflare processes your IP address
          on every request to this website and to the apps' server, to deliver it and protect it.
          For security, Cloudflare keeps a sample of those requests, including the IP address, the
          address requested and details Cloudflare derives from the IP such as the country, for up
          to 31 days, and MadeGood's maintainers can look them up in Cloudflare's security analytics
          (
          <a
            href="https://developers.cloudflare.com/waf/analytics/security-analytics/"
            className={link}
          >
            Cloudflare's documentation
          </a>
          ). MadeGood uses these records only to protect the service from abuse.
        </p>
        <p>
          <strong>Logs.</strong> When something fails, MadeGood's own server code logs only a
          severity and a fixed event name, such as “account deletion retry”: never your account or
          session IDs, handle, name, location, tokens, IP address, the address requested or error
          details. MadeGood keeps Cloudflare's stored Workers logs, traces and log exports turned
          off. A maintainer watching the live log stream while debugging can see request addresses
          and headers as they happen; that stream is not stored.
        </p>
        <p>
          <strong>Rate limits.</strong> To slow down abuse, signing in and refreshing a sign-in are
          limited per IP address (60 requests a minute), and uploads per account. Cloudflare's rate
          limiter counts the requests for each one-minute window. MadeGood's own code does not write
          the IP address to its database, files or logs. A request over the limit is refused and can
          be retried a minute later.
        </p>
      </Section>

      <Section id="control" title="Your control: export and deletion">
        <ul>
          <li>
            Export a session as GPX or its raw recording from the iPhone, or all recordings on the
            iPhone from Settings. Export everything in your account from{" "}
            <Link to="/settings" className={link}>
              Settings
            </Link>{" "}
            on this website: ZIP files with your profile, settings, privacy zones, session details
            and every track as you uploaded it (large accounts come in several parts). The server
            prepares the files in the background and keeps them for 7 days, available only to you,
            then deletes them; a record of the export (its status, size and any error, no data from
            your sessions) is kept for 30 days after that. You can start up to three exports a day.
          </li>
          <li>
            Delete a session, and it is removed from the server at once. A device that still has the
            recording will not upload it again.
          </li>
          <li>
            Delete your account in the iPhone app (Settings → Account → Delete Account) or on this
            website's Settings page. At that moment every sign-in ends and the account is locked: it
            cannot sign in, nothing can be added to it, and your shared sessions, tracks, route
            images and profile disappear for everyone else, even before the data is gone. The same
            request deletes your sessions, tracks, privacy zones, settings, voyages, shared
            positions and data exports (any export in progress stops, and its files are deleted). If
            any part of that fails, the server tries again automatically, waiting longer after each
            failure up to a fixed limit, and keeps trying. The account record itself, with the
            deleted session IDs, is deleted last: no sooner than 20 minutes after your request, and
            only once that cleanup has succeeded, so it takes longer while a step keeps failing.
            Only then can the same Apple ID start a new, empty account. Recordings on your devices
            and workouts in Apple Health are not affected.
          </li>
          <li>
            Processing a track after upload goes through a queue. A job that keeps failing is set
            aside for up to 4 days (Cloudflare's queue retention) so the problem can be fixed; such
            a job holds only IDs (session, account, revision), no positions, and is deleted when it
            expires or is replayed. A job for a deleted account does nothing.
          </li>
          <li>
            Data stays on the server until you delete it. Cloudflare's database recovery can keep
            deleted rows for up to 30 days before they are gone for good.
          </li>
        </ul>
      </Section>

      <Section id="children" title="Children">
        <p>MadeGood is not directed at children and does not knowingly collect their data.</p>
      </Section>

      <Section id="contact" title="Changes and contact">
        <p>
          When the apps or the server change what they collect, this page changes with them. Every
          version is public: the{" "}
          <a href={HISTORY_URL} className={link}>
            history of this policy
          </a>{" "}
          since November 2026, and{" "}
          <a href={EARLIER_HISTORY_URL} className={link}>
            earlier versions
          </a>{" "}
          from before it moved to its own file. Questions or requests: email{" "}
          <a href="mailto:support@madegood.app" className={link}>
            support@madegood.app
          </a>
          , see{" "}
          <Link to="/support" className={link}>
            Support
          </Link>
          , or open an issue on{" "}
          <a href={ISSUES_URL} className={link}>
            GitHub
          </a>{" "}
          (issues are public, so leave out personal details). For a security problem, follow the
          project's{" "}
          <a href={`${GITHUB_URL}/security/policy`} className={link}>
            security policy
          </a>{" "}
          instead.
        </p>
      </Section>
    </article>
  );
}
