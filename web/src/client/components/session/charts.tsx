import { useMemo } from "react";
import {
  CartesianGrid,
  Line,
  LineChart,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { Units } from "@/lib/api";
import { formatDuration, speedUnit, toSpeed } from "@/lib/format";
import { type Track, thin } from "@/lib/track";

const MAX_POINTS = 800;

type Point = { t: number; value: number | null };

function SeriesChart({
  title,
  data,
  unit,
  color,
  cursorT,
  onSeek,
  endT,
}: {
  title: string;
  data: Point[];
  unit: string;
  color: string;
  cursorT: number;
  onSeek: (t: number) => void;
  endT: number;
}) {
  return (
    <figure className="rounded-xl border bg-card p-3">
      <figcaption className="mb-1 text-sm font-medium">
        {title} <span className="text-muted-foreground">({unit})</span>
      </figcaption>
      <div className="h-40">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart
            data={data}
            margin={{ top: 4, right: 8, bottom: 0, left: -16 }}
            onClick={(state) => {
              const t = Number(state?.activeLabel);
              if (Number.isFinite(t)) onSeek(t);
            }}
          >
            <CartesianGrid stroke="var(--border)" vertical={false} />
            <XAxis
              dataKey="t"
              type="number"
              domain={[0, endT]}
              tickFormatter={(t: number) => formatDuration(t)}
              tick={{ fontSize: 11, fill: "var(--muted-foreground)" }}
              stroke="var(--border)"
              minTickGap={40}
            />
            <YAxis
              tick={{ fontSize: 11, fill: "var(--muted-foreground)" }}
              stroke="var(--border)"
              width={48}
              domain={[0, "auto"]}
            />
            <Tooltip
              contentStyle={{
                background: "var(--card)",
                border: "1px solid var(--border)",
                borderRadius: 8,
                fontSize: 12,
              }}
              labelStyle={{ color: "var(--muted-foreground)" }}
              labelFormatter={(t) => formatDuration(Number(t))}
              formatter={(value) => [`${Number(value).toFixed(1)} ${unit}`, title]}
            />
            <Line
              type="monotone"
              dataKey="value"
              stroke={color}
              dot={false}
              strokeWidth={1.75}
              isAnimationActive={false}
              connectNulls={false}
            />
            <ReferenceLine x={cursorT} stroke="var(--foreground)" strokeOpacity={0.6} />
          </LineChart>
        </ResponsiveContainer>
      </div>
    </figure>
  );
}

export default function SessionCharts({
  track,
  units,
  cursorT,
  onSeek,
}: {
  track: Track;
  units: Units;
  cursorT: number;
  onSeek: (t: number) => void;
}) {
  const speed = useMemo(
    () =>
      thin(track.fixes, MAX_POINTS).map((f) => ({
        t: f.t,
        value: f.spd === null ? null : toSpeed(f.spd, units),
      })),
    [track, units],
  );
  const hr = useMemo(
    () => thin(track.hr, MAX_POINTS).map((h) => ({ t: h.t, value: h.bpm })),
    [track],
  );
  return (
    <div className="grid gap-4 lg:grid-cols-2">
      {speed.length > 1 && (
        <SeriesChart
          title="Speed"
          data={speed}
          unit={speedUnit(units)}
          color="var(--primary)"
          cursorT={cursorT}
          onSeek={onSeek}
          endT={track.endT}
        />
      )}
      {hr.length > 1 && (
        <SeriesChart
          title="Heart rate"
          data={hr}
          unit="bpm"
          color="#d42a20"
          cursorT={cursorT}
          onSeek={onSeek}
          endT={track.endT}
        />
      )}
    </div>
  );
}
