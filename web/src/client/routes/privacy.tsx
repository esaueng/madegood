import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";

export const Route = createFileRoute("/privacy")({
  component: Privacy,
});

const GITHUB_URL = "https://github.com/esaueng/madegood";
const ISSUES_URL = `${GITHUB_URL}/issues`;
const HISTORY_URL = `${GITHUB_URL}/commits/main/web/src/client/routes/privacy.tsx`;

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

function Privacy() {
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
        <p>While you record a session, the apps use:</p>
        <ul>
          <li>
            <strong>Location</strong>, while you are recording, to measure your track, speed and
            course. The iPhone keeps recording with the screen off and shows the system location
            indicator. If you turn on local conditions, the iPhone also reads its position while the
            start screen is open (below).
          </li>
          <li>
            <strong>Motion</strong> sensors during a session, to count paddle strokes.
          </li>
          <li>
            <strong>Apple Health</strong>, with your permission: heart rate during a session, and
            saving the session to Health as a workout with its route, for the sports where you turn
            on Save to Health.
          </li>
        </ul>
        <p>
          Recordings are stored in the app on your devices; the watch hands its recordings to your
          iPhone. Settings are stored on the device and kept in step between your watch and iPhone.
          Maps in the apps are Apple Maps, which loads map images from Apple for the area on screen.
        </p>
        <p>Without an account, only these leave your devices:</p>
        <ul>
          <li>
            <strong>Open-Meteo wind</strong>, only when you tap “Compare with Open-Meteo” on a
            sailing session. The iPhone sends{" "}
            <a href="https://open-meteo.com" className={link}>
              Open-Meteo
            </a>{" "}
            the session's average position rounded to 0.5° (about 50 km) and its dates, with no
            account, identifier or cookie, and gets back the modelled wind. (The server can also ask
            Open-Meteo for shared sessions; see below.)
          </li>
          <li>
            <strong>Open-Meteo local conditions</strong>, only if you turn them on (Show on the
            start screen, or Settings → Weather). While the start screen is open, at most every 15
            minutes, the iPhone sends Open-Meteo its position rounded to 0.1° (about 10 km), with no
            account, identifier or cookie, and gets back the current weather and the next few hours.
            The position is not stored; the last answer is kept on the iPhone.
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
          never your email address, and you can choose not to share it. When you turn on sync, the
          iPhone uploads the sessions you recorded while signed in (earlier ones only if you
          choose). The server then holds:
        </p>
        <ul>
          <li>
            <strong>Identifiers:</strong> Apple's identifier for your sign-in, an account ID and a
            handle, and your name if you shared it.
          </li>
          <li>
            <strong>Sessions:</strong> sport, times, distance, speeds, laps and other statistics,
            title and notes, visibility, and the track file: your GPS positions and, if recorded,
            heart rate.
          </li>
          <li>
            <strong>Settings:</strong> units, the default visibility of new sessions, and your
            privacy zones (a center and radius each).
          </li>
          <li>
            <strong>Sign-in tokens</strong>, stored as hashes, so the apps and this website stay
            signed in. MadeGood holds no tokens from Apple.
          </li>
          <li>
            <strong>Data worked out from each track</strong> after it is uploaded: the area it
            covers (a bounding box), a coarse start location (geohash), the times of the first and
            last position, and for shared sessions a second bounding box and times with your privacy
            zones cut out, and the wind (below). Only you see the first set; others see only the
            version with your zones cut out.
          </li>
          <li>
            <strong>Deleted session IDs:</strong> when you delete a session, its ID and the time are
            kept so a device that still has the recording cannot upload it again. They are removed
            with your account.
          </li>
        </ul>
        <p>
          <strong>Wind for shared sessions.</strong> When a session is unlisted or public, the
          server asks{" "}
          <a href="https://open-meteo.com" className={link}>
            Open-Meteo
          </a>{" "}
          for the wind during it, automatically. It uses only what others can see of the track, with
          your privacy zones cut out: one position, the center of that visible area, rounded to 0.1°
          (about 11 km), and the UTC dates the visible part spans. No account, session ID, track or
          time of day is sent. Private sessions never cause a request, and neither does a shared
          session whose whole track lies inside your privacy zones. The answer is stored with the
          session.
        </p>
        <p>
          The raw motion data the watch records stays on your devices. Your data is used only to
          show you your sessions, sync them and share what you choose to share.
        </p>
      </Section>

      <Section id="voyages" title="Voyages">
        <p>
          Voyages (multi-day passages made of legs) are recorded on the iPhone and stay there.
          Syncing them to the server and sharing them live are being built and are{" "}
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
          Every session is private until you change it. An <em>unlisted</em> session can be seen by
          anyone with its link; a <em>public</em> session by anyone. Others see its track,
          statistics, title and notes, but not your heart rate, and parts of the track inside your
          privacy zones are cut out.
        </p>
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
            a privacy zone, and only when you click it.
          </li>
        </ul>
      </Section>

      <Section id="hosting" title="Where it runs">
        <p>
          The server and this website run on Cloudflare (Workers, D1, R2, Queues and Durable
          Objects). Cloudflare keeps request logs, which include IP addresses and the addresses of
          the pages and API calls requested, for a limited time, to run and debug the service.
          MadeGood uses no other services and gives your data to no one else.
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
            cannot sign in, and nothing can be read from it or added to it. The same request deletes
            your sessions, tracks, privacy zones, settings, voyages, shared positions and data
            exports (any export in progress stops, and its files are deleted). If any part of that
            fails, the server tries again, every 30 minutes at first and at least every 6 hours,
            until it is done. About 20 minutes after your request (at the next run after that) the
            account record itself is deleted, with the deleted session IDs; only then can the same
            Apple ID start a new, empty account. Recordings on your devices and workouts in Apple
            Health are not affected.
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
          When the apps or the server change what they collect, this page changes with them; its{" "}
          <a href={HISTORY_URL} className={link}>
            history
          </a>{" "}
          is public. Questions or requests: open an issue on{" "}
          <a href={ISSUES_URL} className={link}>
            GitHub
          </a>
          . For a security problem, follow the project's{" "}
          <a href={`${GITHUB_URL}/security/policy`} className={link}>
            security policy
          </a>{" "}
          instead.
        </p>
      </Section>
    </article>
  );
}
