import "maplibre-gl/dist/maplibre-gl.css";
import type { StyleSpecification } from "maplibre-gl";
import { useMemo, useState } from "react";
import MapGL, { Layer, Marker, NavigationControl, Source } from "react-map-gl/maplibre";
import { bounds, type Fix, SPEED_BINS, speedLines, type Track } from "@/lib/track";
import { SPEED_COLORS } from "./colors";

// OpenStreetMap raster tiles with the OpenSeaMap seamark overlay as an option (PLAN §2:
// Protomaps in R2 replaces the base tiles later). Neither is an official chart, so the
// map always carries "Not for navigation".
const OSM_ATTRIBUTION =
  '© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a> contributors';
const SEAMARK_ATTRIBUTION =
  'Seamarks © <a href="https://www.openseamap.org" target="_blank" rel="noreferrer">OpenSeaMap</a> contributors';

export const mapStyle = (seamarks: boolean): StyleSpecification => ({
  version: 8,
  sources: {
    osm: {
      type: "raster",
      tiles: ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      tileSize: 256,
      maxzoom: 19,
      attribution: OSM_ATTRIBUTION,
    },
    ...(seamarks
      ? {
          seamarks: {
            type: "raster" as const,
            tiles: ["https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png"],
            tileSize: 256,
            maxzoom: 18,
            attribution: SEAMARK_ATTRIBUTION,
          },
        }
      : {}),
  },
  layers: [
    { id: "osm", type: "raster", source: "osm" },
    ...(seamarks ? [{ id: "seamarks", type: "raster" as const, source: "seamarks" }] : []),
  ],
});

const colorExpression = [
  "match",
  ["get", "bin"],
  ...SPEED_COLORS.slice(0, SPEED_BINS).flatMap((color, bin) => [bin, color]),
  "#8a8f98",
] as unknown as string;

export default function TrackMap({
  track,
  maxSpeed,
  cursor,
}: {
  track: Track;
  maxSpeed: number;
  cursor: Fix | null;
}) {
  const [seamarks, setSeamarks] = useState(false);
  const style = useMemo(() => mapStyle(seamarks), [seamarks]);
  const lines = useMemo(() => speedLines(track, maxSpeed), [track, maxSpeed]);
  const box = useMemo(() => bounds(track.fixes), [track]);
  const start = track.fixes[0];
  const end = track.fixes.at(-1);

  if (!box) return null;
  return (
    <div className="relative h-[55vh] min-h-72 overflow-hidden rounded-xl border sm:h-[28rem]">
      <MapGL
        initialViewState={{ bounds: box, fitBoundsOptions: { padding: 40, maxZoom: 16 } }}
        mapStyle={style}
        style={{ width: "100%", height: "100%" }}
        attributionControl={{ compact: true }}
        dragRotate={false}
        touchPitch={false}
      >
        <NavigationControl position="top-right" showCompass={false} />
        <Source id="track" type="geojson" data={lines}>
          <Layer
            id="track-casing"
            type="line"
            layout={{ "line-join": "round", "line-cap": "round" }}
            paint={{ "line-color": "#ffffff", "line-width": 6, "line-opacity": 0.8 }}
          />
          <Layer
            id="track-line"
            type="line"
            layout={{ "line-join": "round", "line-cap": "round" }}
            paint={{ "line-color": colorExpression, "line-width": 3.5 }}
          />
        </Source>
        {start && (
          <Marker longitude={start.lon} latitude={start.lat}>
            <span
              title="Start"
              className="block size-3 rounded-full border-2 border-white bg-emerald-600 shadow"
            />
          </Marker>
        )}
        {end && end !== start && (
          <Marker longitude={end.lon} latitude={end.lat}>
            <span
              title="Finish"
              className="block size-3 rounded-full border-2 border-white bg-neutral-900 shadow"
            />
          </Marker>
        )}
        {cursor && (
          <Marker longitude={cursor.lon} latitude={cursor.lat}>
            <span className="block size-4 rounded-full border-[3px] border-white bg-primary shadow-md" />
          </Marker>
        )}
      </MapGL>
      <div className="pointer-events-none absolute top-2 left-2 rounded bg-white/90 px-2 py-0.5 text-xs font-semibold text-neutral-900 shadow">
        Not for navigation
      </div>
      <label className="absolute bottom-2 left-2 flex items-center gap-1.5 rounded bg-white/90 px-2 py-1 text-xs text-neutral-900 shadow">
        <input
          type="checkbox"
          checked={seamarks}
          onChange={(event) => setSeamarks(event.target.checked)}
        />
        Seamarks
      </label>
    </div>
  );
}
