import { initWasm, Resvg } from "@resvg/resvg-wasm";
import resvgWasm from "@resvg/resvg-wasm/index_bg.wasm";
import displaySemibold from "./fonts/inter-display-semibold.latin.ttf.bin";
import textMedium from "./fonts/inter-medium.latin.ttf.bin";

// SVG → PNG with resvg compiled to WebAssembly (about 2.5 MB, 0.95 MB gzipped). It is the
// smallest renderer that runs in Workers, draws gradients, masks and blur, and shapes text
// with our own fonts; satori would add a layout engine we don't need on top of it. Fonts
// are Inter (SIL OFL 1.1, og/fonts/OFL.txt) subset to Latin, since the cards only print
// sport names, numbers and units.

let ready: Promise<void> | null = null;

function init(): Promise<void> {
  ready ??= initWasm(resvgWasm).catch((error: unknown) => {
    ready = null;
    throw error;
  });
  return ready;
}

const fontBuffers = [new Uint8Array(displaySemibold), new Uint8Array(textMedium)];

/** Renders an SVG document to PNG bytes at its own size. */
export async function svgToPng(svg: string): Promise<Uint8Array> {
  await init();
  const resvg = new Resvg(svg, {
    font: { fontBuffers, defaultFontFamily: "Inter" },
    shapeRendering: 2,
    textRendering: 1,
  });
  try {
    const image = resvg.render();
    try {
      return image.asPng();
    } finally {
      image.free();
    }
  } finally {
    resvg.free();
  }
}
