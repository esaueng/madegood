import "maplibre-gl/dist/maplibre-gl.css";
import { useMemo } from "react";
import MapGL, { Layer, NavigationControl, Source } from "react-map-gl/maplibre";
import type { PrivacyZone } from "@/lib/api";
import { mapStyle } from "./session/track-map";

/** A circle as a 64-sided polygon (spherical approximation; ample for display). */
function circle(lat: number, lon: number, radiusM: number): [number, number][] {
  const points: [number, number][] = [];
  const dLat = radiusM / 111_195;
  const dLon = dLat / Math.max(0.01, Math.cos((lat * Math.PI) / 180));
  for (let i = 0; i <= 64; i++) {
    const a = (i / 64) * 2 * Math.PI;
    points.push([lon + dLon * Math.sin(a), lat + dLat * Math.cos(a)]);
  }
  return points;
}

export type Draft = { lat: number; lon: number; radiusM: number };

export default function ZoneMap({
  zones,
  draft,
  onPick,
}: {
  zones: PrivacyZone[];
  draft: Draft | null;
  onPick: (lat: number, lon: number) => void;
}) {
  const style = useMemo(() => mapStyle(false), []);
  const shapes = useMemo(
    () => ({
      type: "FeatureCollection" as const,
      features: [
        ...zones.map((z) => ({ ...z, kind: "saved" })),
        ...(draft ? [{ ...draft, kind: "draft" }] : []),
      ].map((z) => ({
        type: "Feature" as const,
        properties: { kind: z.kind },
        geometry: { type: "Polygon" as const, coordinates: [circle(z.lat, z.lon, z.radiusM)] },
      })),
    }),
    [zones, draft],
  );
  const first = zones[0];
  return (
    <div className="relative h-80 overflow-hidden rounded-xl border sm:h-96">
      <MapGL
        initialViewState={
          first
            ? { latitude: first.lat, longitude: first.lon, zoom: 12 }
            : { latitude: 30, longitude: 0, zoom: 1 }
        }
        mapStyle={style}
        style={{ width: "100%", height: "100%" }}
        attributionControl={{ compact: true }}
        dragRotate={false}
        touchPitch={false}
        cursor="crosshair"
        onClick={(event) => onPick(event.lngLat.lat, event.lngLat.lng)}
      >
        <NavigationControl position="top-right" showCompass={false} />
        <Source id="zones" type="geojson" data={shapes}>
          <Layer
            id="zone-fill"
            type="fill"
            paint={{
              "fill-color": ["match", ["get", "kind"], "draft", "#2c5fd1", "#d42a20"],
              "fill-opacity": 0.2,
            }}
          />
          <Layer
            id="zone-line"
            type="line"
            paint={{
              "line-color": ["match", ["get", "kind"], "draft", "#2c5fd1", "#d42a20"],
              "line-width": 2,
            }}
          />
        </Source>
      </MapGL>
      <div className="pointer-events-none absolute top-2 left-2 rounded bg-white/90 px-2 py-0.5 text-xs font-semibold text-neutral-900 shadow">
        Not for navigation
      </div>
    </div>
  );
}
