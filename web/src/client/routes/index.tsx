import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import {
  Code,
  Download,
  ExternalLink,
  HeartPulse,
  Lock,
  Map as MapIcon,
  Smartphone,
  Watch,
} from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { fetchHealth } from "@/lib/api";
import { cn } from "@/lib/utils";

export const Route = createFileRoute("/")({
  component: Home,
});

const GITHUB_URL = "https://github.com/esaueng/madegood";

// Set this to the public TestFlight or App Store link once there is one. Until then the
// page shows the release status as text and links nowhere.
const DOWNLOAD_URL: string | null = null;

// The shared button focus ring (ring/50) is too faint on this page's surfaces; the
// landing page's calls to action use a foreground-colored ring with an offset instead
// (well over 3:1 against the background in both themes).
const ctaFocus =
  "focus-visible:ring-2 focus-visible:ring-foreground focus-visible:ring-offset-2 focus-visible:ring-offset-background";
const cta = ({ variant }: { variant?: "default" | "outline" } = {}) =>
  cn(buttonVariants({ variant, size: "lg" }), ctaFocus);
const linkFocus =
  "rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground";

const sports = [
  { name: "Sailing", metrics: "Tacks and gybes, wind estimate, VMG, start countdown" },
  {
    name: "Windsurfing",
    metrics: "Speedsurfing bests: 2 s, 10 s, 5×10 s, 500 m, nautical mile, alpha 500",
  },
  { name: "Kayak", metrics: "Stroke rate, stroke count, distance per stroke" },
  { name: "Canoe and SUP", metrics: "Stroke rate, stroke count, distance per stroke" },
  { name: "Motorboating", metrics: "Nautical-mile trip log, engine time, fuel estimate" },
];

const features = [
  {
    icon: Watch,
    title: "Apple Watch first",
    body: "Start from your wrist, see live numbers, mark a man-overboard position, and lock the screen against spray. The watch records on its own and hands the session to your phone.",
  },
  {
    icon: Smartphone,
    title: "iPhone on its own, too",
    body: "Record from the phone in a dry bag or at the helm, with a Live Activity on the Lock Screen. Review each session with a speed-colored map, charts, and replay.",
  },
  {
    icon: HeartPulse,
    title: "Apple Health",
    body: "Sessions can be saved to Apple Health as workouts with the route and heart rate. You choose per sport.",
  },
  {
    icon: Lock,
    title: "Private by default",
    body: "No account needed: you can record and review sessions on your devices without a connection. Sync is optional, sessions stay private until you share them, and privacy zones hide places you choose, like home, from shared tracks.",
  },
  {
    icon: MapIcon,
    title: "Replay and share",
    body: "Sign in on the web to browse, replay, and share your sessions. Shared links show a preview. On the iPhone, export any session as GPX.",
  },
  {
    icon: Code,
    title: "Open source",
    body: "Apache 2.0. The app, the algorithms, and this website are on GitHub, and you can run your own copy of the backend on Cloudflare.",
  },
];

const phoneShots = [
  {
    src: "/screenshots/iphone-sailing-live.webp",
    alt: "iPhone recording a sailing session: speed 4.9 knots, VMG, heading, estimated wind axis and tack count.",
    caption: "Sailing, live",
  },
  {
    src: "/screenshots/iphone-sailing-detail.webp",
    alt: "Sailing session summary: distance in nautical miles, average and best speeds, heart rate chart and a list of tacks and gybes.",
    caption: "Session summary",
  },
  {
    src: "/screenshots/iphone-kayak-strokes.webp",
    alt: "Kayak session in dark mode: stroke count, average stroke rate, distance per stroke and a stroke rate chart.",
    caption: "Paddling strokes",
  },
  {
    src: "/screenshots/iphone-motorboat-log.webp",
    alt: "Motorboat session: trip log in nautical miles, engine time and an estimated fuel use.",
    caption: "Motorboat trip log",
  },
];

const watchShots = [
  {
    src: "/screenshots/watch-start.webp",
    alt: "Apple Watch start screen with sport tiles for sailing, windsurfing and motorboating.",
    caption: "Pick a sport",
  },
  {
    src: "/screenshots/watch-countdown.webp",
    alt: "Apple Watch start countdown for a sailing session with one minute four seconds left.",
    caption: "Start countdown",
  },
];

function Home() {
  return (
    <>
      <section aria-labelledby="hero-title" className="py-16 sm:py-24">
        <h1 id="hero-title" className="max-w-2xl text-4xl font-bold tracking-tight sm:text-5xl">
          Track your time on the water.
        </h1>
        <p className="mt-4 max-w-xl text-lg text-muted-foreground">
          MadeGood records sailing, windsurfing, paddling, and motorboating sessions on Apple Watch
          and iPhone, and turns them into numbers that fit your sport. It is free and open source,
          and your sessions are private unless you share them.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <DownloadButton />
          <a href={GITHUB_URL} className={cta({ variant: "outline" })}>
            <Code aria-hidden />
            View on GitHub
          </a>
        </div>
      </section>

      <section aria-labelledby="sports-title" className="pb-16">
        <h2 id="sports-title" className="text-2xl font-semibold tracking-tight">
          Made for your sport
        </h2>
        <ul className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {sports.map(({ name, metrics }) => (
            <li key={name} className="rounded-xl border bg-card p-4">
              <h3 className="font-semibold">{name}</h3>
              <p className="mt-1 text-sm text-muted-foreground">{metrics}</p>
            </li>
          ))}
          <li className="rounded-xl border bg-card p-4">
            <h3 className="font-semibold">Every session</h3>
            <p className="mt-1 text-sm text-muted-foreground">
              Distance, GPS Doppler speed with 2 s and 10 s bests, laps, heart rate
            </p>
          </li>
        </ul>
      </section>

      <section aria-labelledby="screens-title" className="pb-16">
        <h2 id="screens-title" className="text-2xl font-semibold tracking-tight">
          See it
        </h2>
        <p className="mt-2 text-sm text-muted-foreground">
          Screenshots from the app's automated tests, recorded with a made-up demo session.
        </p>
        <ul className="mt-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
          {phoneShots.map((shot) => (
            <Screenshot key={shot.src} {...shot} width={402} height={874} rounded="rounded-3xl" />
          ))}
        </ul>
        <ul className="mt-6 grid max-w-md grid-cols-2 gap-4">
          {watchShots.map((shot) => (
            <Screenshot
              key={shot.src}
              {...shot}
              width={208}
              height={248}
              rounded="rounded-[2rem]"
            />
          ))}
        </ul>
      </section>

      <section aria-labelledby="features-title" className="pb-16">
        <h2 id="features-title" className="text-2xl font-semibold tracking-tight">
          What you get
        </h2>
        <ul className="mt-6 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {features.map(({ icon: Icon, title, body }) => (
            <li key={title} className="rounded-xl border bg-card p-5">
              <Icon className="size-6 text-primary" aria-hidden />
              <h3 className="mt-3 font-semibold">{title}</h3>
              <p className="mt-1 text-sm text-muted-foreground">{body}</p>
            </li>
          ))}
        </ul>
        <p className="mt-6 text-sm text-muted-foreground">
          Coming later: Voyages, a passage log for longer trips with routes, live position sharing,
          and boat instruments.
        </p>
      </section>

      <section
        aria-labelledby="download-title"
        className="mb-16 rounded-xl border bg-card p-6 sm:p-8"
      >
        <h2 id="download-title" className="text-2xl font-semibold tracking-tight">
          Get MadeGood
        </h2>
        <p className="mt-2 max-w-xl text-muted-foreground">
          {DOWNLOAD_URL
            ? "MadeGood is in beta on TestFlight. It needs iOS 26 and, for the watch app, watchOS 26."
            : "MadeGood is coming soon to TestFlight and the App Store. It will need iOS 26 and, for the watch app, watchOS 26. Until then you can build it yourself from the source."}
        </p>
        <div className="mt-6 flex flex-wrap gap-3">
          <DownloadButton />
          <a href={GITHUB_URL} className={cta({ variant: "outline" })}>
            <ExternalLink aria-hidden />
            Source on GitHub
          </a>
        </div>
        <p className="mt-6 text-xs text-muted-foreground">
          MadeGood is not for navigation. Its numbers are personal records, not certified
          measurements.
        </p>
      </section>

      <Footer />
    </>
  );
}

function DownloadButton() {
  if (DOWNLOAD_URL) {
    return (
      <a href={DOWNLOAD_URL} className={cta()}>
        <Download aria-hidden />
        Join the beta
      </a>
    );
  }
  // Plain status text, not a disabled control: nothing suggests a download exists yet, and
  // the text keeps full contrast.
  return (
    <p className="inline-flex h-10 items-center gap-2 rounded-md border border-dashed px-4 text-sm font-medium text-foreground">
      <Download className="size-4" aria-hidden />
      Coming soon to TestFlight and the App Store
    </p>
  );
}

function Screenshot({
  src,
  alt,
  caption,
  width,
  height,
  rounded,
}: {
  src: string;
  alt: string;
  caption: string;
  width: number;
  height: number;
  rounded: string;
}) {
  return (
    <li>
      <figure>
        <img
          src={src}
          alt={alt}
          width={width}
          height={height}
          loading="lazy"
          decoding="async"
          className={cn("h-auto w-full border bg-muted", rounded)}
        />
        <figcaption className="mt-2 text-center text-sm text-muted-foreground">
          {caption}
        </figcaption>
      </figure>
    </li>
  );
}

function Footer() {
  return (
    <footer className="flex flex-col gap-2 border-t py-6 text-xs text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
      <p>
        Open source under the{" "}
        <a
          href={`${GITHUB_URL}/blob/main/LICENSE`}
          className={cn("underline underline-offset-2", linkFocus)}
        >
          Apache License 2.0
        </a>
        .{" "}
        <a href={GITHUB_URL} className={cn("underline underline-offset-2", linkFocus)}>
          GitHub
        </a>
        .{" "}
        <Link to="/privacy" className={cn("underline underline-offset-2", linkFocus)}>
          Privacy
        </Link>
      </p>
      <ApiStatus />
    </footer>
  );
}

function ApiStatus() {
  const { data, isError, isPending } = useQuery({ queryKey: ["health"], queryFn: fetchHealth });
  const label = isPending
    ? "checking…"
    : isError
      ? "unreachable"
      : `${data.status} · v${data.version}`;
  return <p>API: {label}</p>;
}
