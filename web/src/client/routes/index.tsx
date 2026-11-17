import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Anchor, Sailboat, Waves } from "lucide-react";
import { Button } from "@/components/ui/button";
import { fetchHealth } from "@/lib/api";

export const Route = createFileRoute("/")({
  component: Home,
});

const features = [
  {
    icon: Sailboat,
    title: "Sessions",
    body: "Watch-first tracking for sailing, windsurfing, motorboating, kayak, canoe, and SUP, with tacks, VMG, speed bests, and stroke rate.",
  },
  {
    icon: Anchor,
    title: "Voyages",
    body: "A passage log for longer trips: routes and waypoints, live position sharing, and boat instruments over NMEA and Signal K.",
  },
  {
    icon: Waves,
    title: "Yours",
    body: "Works offline with no account. Sync and sharing are optional, and sessions are private by default. Open source under Apache 2.0.",
  },
];

function Home() {
  return (
    <>
      <section className="py-16 sm:py-24">
        <h1 className="max-w-2xl text-4xl font-bold tracking-tight sm:text-5xl">
          Track your time on the water.
        </h1>
        <p className="mt-4 max-w-xl text-lg text-muted-foreground">
          MadeGood is an open-source app for iPhone and Apple Watch, with a website to replay and
          share your sessions. It is in early development.
        </p>
        <div className="mt-8 flex gap-3">
          <Button disabled>Coming to the App Store</Button>
        </div>
      </section>
      <section className="grid gap-6 pb-16 sm:grid-cols-3">
        {features.map(({ icon: Icon, title, body }) => (
          <div key={title} className="rounded-xl border bg-card p-5">
            <Icon className="size-6 text-primary" aria-hidden />
            <h2 className="mt-3 font-semibold">{title}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{body}</p>
          </div>
        ))}
      </section>
      <ApiStatus />
    </>
  );
}

function ApiStatus() {
  const { data, isError, isPending } = useQuery({ queryKey: ["health"], queryFn: fetchHealth });
  const label = isPending
    ? "checking…"
    : isError
      ? "unreachable"
      : `${data.status} · v${data.version}`;
  return <footer className="border-t py-6 text-xs text-muted-foreground">API: {label}</footer>;
}
