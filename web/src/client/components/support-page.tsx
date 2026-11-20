import { Link } from "@tanstack/react-router";
import { Bug, ChevronDown, Mail, TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";

// The App Store support page (/support). Answer only from what ships: each answer names the
// screens and labels the apps and this website use today. Check them when those change.

/** The question ID a URL fragment such as "#delete-account" names; "" if none or malformed. */
export function questionId(hash: string): string {
  try {
    return decodeURIComponent(hash.replace(/^#/, ""));
  } catch {
    // A malformed fragment such as "#%" opens nothing; the page stays usable.
    return "";
  }
}

export const SUPPORT_EMAIL = "support@madegood.app";
const GITHUB_URL = "https://github.com/esaueng/madegood";
const ISSUES_URL = `${GITHUB_URL}/issues`;

const link = "underline underline-offset-2";
const bullets = "list-disc pl-5 [&_li]:mt-1.5";
const focusRing =
  "rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground";

/** A path through the apps' screens, such as Settings → Account. */
function Path({ children }: { children: ReactNode }) {
  return <span className="font-medium text-foreground">{children}</span>;
}

function Question({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <details id={id} className="group scroll-mt-6">
      <summary
        className={`flex cursor-pointer list-none items-center justify-between gap-4 py-4 font-medium [&::-webkit-details-marker]:hidden ${focusRing}`}
      >
        {title}
        <ChevronDown
          className="size-4 shrink-0 text-muted-foreground transition-transform group-open:rotate-180"
          aria-hidden
        />
      </summary>
      <div className="grid gap-3 pb-5 text-muted-foreground">{children}</div>
    </details>
  );
}

export function SupportPage() {
  return (
    <article className="mx-auto grid max-w-prose gap-12 py-10 leading-relaxed">
      <header className="grid gap-3">
        <h1 className="text-3xl font-bold tracking-tight">Support</h1>
        <p className="text-lg text-muted-foreground">
          Help with MadeGood on iPhone, Apple Watch and this website. Many questions are answered
          below; if yours isn't, get in touch.
        </p>
      </header>

      <section aria-labelledby="contact" className="grid gap-4">
        <h2 id="contact" className="text-xl font-semibold tracking-tight">
          Contact
        </h2>
        <ul className="grid gap-3 sm:grid-cols-2">
          <li className="grid content-start gap-2 rounded-xl border bg-card p-5">
            <Mail className="size-5 text-primary" aria-hidden />
            <h3 className="font-semibold">Email</h3>
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className={`w-fit break-all font-medium text-primary ${link} ${focusRing}`}
            >
              {SUPPORT_EMAIL}
            </a>
            <p className="text-sm text-muted-foreground">
              Questions, help with your account, and anything you'd rather not post in public.
            </p>
          </li>
          <li className="grid content-start gap-2 rounded-xl border bg-card p-5">
            <Bug className="size-5 text-primary" aria-hidden />
            <h3 className="font-semibold">GitHub issues</h3>
            <a href={ISSUES_URL} className={`w-fit font-medium text-primary ${link} ${focusRing}`}>
              Report a bug or request a feature
            </a>
            <p className="text-sm text-muted-foreground">
              Issues are public. Don't include personal details, session links or locations.
            </p>
          </li>
        </ul>
        <p className="text-sm text-muted-foreground">
          It helps to mention the app version (in the iPhone app under <Path>Settings → About</Path>
          ) and the iOS and watchOS versions you use. Found a security problem? Follow the{" "}
          <a href={`${GITHUB_URL}/security/policy`} className={`${link} ${focusRing}`}>
            security policy
          </a>{" "}
          instead of opening an issue.
        </p>
      </section>

      <section aria-labelledby="questions" className="grid gap-2">
        <h2 id="questions" className="text-xl font-semibold tracking-tight">
          Common questions
        </h2>
        <div className="divide-y border-y">
          <Question id="apple-watch" title="How do sessions get from my Apple Watch to my iPhone?">
            <p>
              MadeGood needs iOS 26 on the iPhone and watchOS 26 on the Apple Watch. Install it on
              the iPhone your watch is paired with; if the watch app doesn't appear, install it from
              the App Store on the watch.
            </p>
            <p>
              The watch records on its own, so the iPhone can stay ashore. When a session ends, the
              watch hands it to MadeGood on your iPhone in the background once the two are
              connected. It keeps the session until the iPhone has stored all of it, so an
              interrupted transfer loses nothing. The watch never connects to MadeGood's servers; if
              you sync, the iPhone uploads the session.
            </p>
            <p>
              Until then the watch's start screen shows how many sessions are waiting for iPhone. If
              they stay there, keep both devices close, open MadeGood on the iPhone and tap{" "}
              <Path>Send again</Path> on the watch. If the watch asks you to update MadeGood on your
              iPhone, do that first; the sessions wait on the watch.
            </p>
          </Question>

          <Question id="account" title="Do I need an account?">
            <p>
              No. You can record on your iPhone and Apple Watch, and review and export sessions on
              your iPhone, without an account or a connection. The watch hands each session to the
              iPhone, where the export controls are.
            </p>
            <p>
              An account is optional. It lets you sync sessions to this website to browse, replay
              and share them. You sign in with Apple: in the iPhone app under{" "}
              <Path>Settings → Account</Path>, then turn on <Path>Sync sessions</Path>. MadeGood
              asks Apple for your name only, never your email address, and you can choose not to
              share it. Sessions recorded before you signed in upload only if you choose.
            </p>
          </Question>

          <Question id="delete-account" title="How do I delete my account?">
            <ul className={bullets}>
              <li>
                In the iPhone app: <Path>Settings → Account → Delete Account</Path>.
              </li>
              <li>
                On this website: sign in, open{" "}
                <Link to="/settings" className={`${link} ${focusRing}`}>
                  Settings
                </Link>{" "}
                and choose <Path>Delete account</Path> at the bottom.
              </li>
            </ul>
            <p>
              This deletes every session you have uploaded, your privacy zones, your settings and
              your sign-in from MadeGood's servers. Recordings on your iPhone and Apple Watch stay
              on those devices, and workouts in Apple Health are not affected. It can't be undone,
              so export your data first if you want a copy.
            </p>
          </Question>

          <Question id="export" title="How do I export my data?">
            <ul className={bullets}>
              <li>
                <strong className="font-medium text-foreground">Everything in your account:</strong>{" "}
                on this website, <Path>Settings → Export your data</Path>. You get ZIP files with
                your profile, settings, privacy zones, each session's details and every track as you
                uploaded it. A large account takes a few minutes; the files are kept for 7 days.
              </li>
              <li>
                <strong className="font-medium text-foreground">Everything on your iPhone:</strong>{" "}
                in the iPhone app, <Path>Settings → Your Data → Export All Recordings</Path>, a ZIP
                file of every recording on that iPhone.
              </li>
              <li>
                <strong className="font-medium text-foreground">One session:</strong> open it in the
                iPhone app and choose <Path>Export GPX</Path> or <Path>Share raw recording</Path>.
              </li>
            </ul>
            <p>Exports contain precise locations and times, so share them with care.</p>
          </Question>

          <Question id="sharing" title="How do sharing, public profiles and privacy zones work?">
            <p>
              Sessions are private unless you choose otherwise. To share one, sign in on this
              website, open the session and set its <Path>Visibility</Path>: <em>Unlisted</em>{" "}
              (anyone with the link) or <em>Public</em> (anyone). Others see the track, statistics,
              title and notes, never your heart rate. Settings sets the visibility new sessions get
              when they upload: it starts as private, and if you change it to Unlisted or Public,
              new sessions are shared that way automatically.
            </p>
            <p>
              Your public profile lists your name, handle and the sessions you make public, with
              their totals. Private and unlisted sessions never appear there, and nobody else can
              open it until you have a public session.
            </p>
            <p>
              Privacy zones hide the parts of your track near places such as home or your usual
              launch spot. They don't change a session's title or notes, so leave places out of
              those if you share it. In{" "}
              <Link to="/settings" className={`${link} ${focusRing}`}>
                Settings
              </Link>{" "}
              on this website, click the map to place a zone and choose its size. Everyone else sees
              your shared sessions with those areas cut out, including sessions shared before you
              added the zone. You always see your whole track.
            </p>
          </Question>

          <Question id="permissions" title="Which permissions does MadeGood ask for, and why?">
            <ul className={bullets}>
              <li>
                <strong className="font-medium text-foreground">Location</strong>, to record your
                track, speed and course while you record a session, including with the screen off.
                On the iPhone it also shows local conditions on the start screen if you turn them
                on, and watches for drift while the anchor alarm is armed (that needs Precise
                Location).
              </li>
              <li>
                <strong className="font-medium text-foreground">Motion &amp; Fitness</strong>, to
                count paddle strokes during a session.
              </li>
              <li>
                <strong className="font-medium text-foreground">Health</strong>, to show your heart
                rate live and in the session summary, and to save sessions to Health as workouts
                with the route, for the sports where you turn on <Path>Save to Health</Path>.
              </li>
              <li>
                <strong className="font-medium text-foreground">Alarms</strong> (iPhone), so the
                anchor alarm can sound if your boat drifts outside the swing radius you set.
              </li>
            </ul>
            <p>You can change any of them later in the Settings app on your iPhone.</p>
          </Question>
        </div>
      </section>

      <section
        aria-labelledby="navigation"
        className="grid gap-3 rounded-xl border border-amber-600/40 bg-amber-500/5 p-5"
      >
        <h2 id="navigation" className="flex items-center gap-2 text-xl font-semibold">
          <TriangleAlert className="size-5 shrink-0 text-amber-600" aria-hidden />
          Not for navigation
        </h2>
        <p>
          MadeGood is not a navigation app or a certified safety device. Its maps and routes are not
          charts, and its numbers are personal records, not certified measurements. Navigate with
          proper charts and instruments.
        </p>
        <p>
          The anchor alarm and man overboard are aids, not safeguards. The anchor alarm depends on
          the iPhone's GPS, battery and alarm settings, and can sound late or not at all, so keep a
          proper anchor watch. Man overboard marks a position and shows the distance and bearing
          back to it; it does not call for help or alert anyone else.
        </p>
      </section>

      <nav aria-label="More" className="flex flex-wrap gap-x-6 gap-y-2 border-t pt-6 text-sm">
        <Link to="/privacy" className={`${link} ${focusRing}`}>
          Privacy policy
        </Link>
        <a href={GITHUB_URL} className={`${link} ${focusRing}`}>
          Source code on GitHub
        </a>
      </nav>
    </article>
  );
}
