import Foundation

/// The self-contained HTML page `waterkit-label` writes for reviewing strokes: the motion
/// signal, the detector's candidates, GPS speed, and the labels being edited. It loads
/// nothing from the network, and carries no positions, dates or identifiers: only
/// session-relative times, the signal, speeds and the labels.
public enum StrokeReviewPage {
    /// The page for `review`, starting from `labels` (a draft or earlier reviewed labels).
    public static func html(review: StrokeReview, labels: FixtureLabelsFile, reviewKey: String) throws -> String {
        let data = try JSONEncoder().encode(payload(review: review, labels: labels, reviewKey: reviewKey))
        // Inside <script>, "</" could close the element; JSON allows "<\/" instead.
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        return template.replacingOccurrences(of: "__REVIEW_DATA__", with: json)
    }

    struct Channel: Encodable {
        var scale: Double
        var data: String
    }

    struct Payload: Encodable {
        var sport: String
        var strokesPerCycle: Int
        var duration: Double
        var signalStart: Double
        var signalInterval: Double
        var channels: [String: Channel]
        var speedT: [Double]
        var speedV: [Double]
        var candidates: [[Double]]
        var notCounted: [[Double]]
        var labels: FixtureLabelsFile
        var reviewKey: String
    }

    static func payload(review: StrokeReview, labels: FixtureLabelsFile, reviewKey: String) -> Payload {
        let signal = review.signal
        var channels = ["main": encode(signal.main)]
        for (name, values) in zip(["rx", "ry", "rz"], signal.rotation) { channels[name] = encode(values) }
        return Payload(
            sport: review.sport.rawValue,
            strokesPerCycle: review.sport == .kayak ? 2 : 1,
            duration: rounded(review.duration, 1000),
            signalStart: rounded(signal.start, 10_000),
            signalInterval: StrokeReviewSignal.interval,
            channels: channels,
            speedT: review.speed.map { rounded($0.t, 100) },
            speedV: review.speed.map { rounded($0.speed, 100) },
            candidates: review.candidates.map { [rounded($0.t, 1000), Double($0.side ?? -1), $0.counted ? 1 : 0] },
            notCounted: review.notCounted.map { [rounded($0.lowerBound, 1000), rounded($0.upperBound, 1000)] },
            labels: labels,
            reviewKey: reviewKey)
    }

    static func rounded(_ value: Double, _ factor: Double) -> Double { (value * factor).rounded() / factor }

    /// Little-endian Int16 samples in base64; -32768 marks a missing value.
    static func encode(_ values: [Double]) -> Channel {
        let peak = values.reduce(0.0) { $1.isFinite ? max($0, abs($1)) : $0 }
        let scale = peak > 0 ? peak / 32_000 : 1
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 2)
        for value in values {
            let quantized: Int16 = value.isFinite ? Int16(max(-32_000, min(32_000, (value / scale).rounded()))) : .min
            let bits = UInt16(bitPattern: quantized)
            bytes.append(UInt8(bits & 0xFF))
            bytes.append(UInt8(bits >> 8))
        }
        return Channel(scale: scale, data: Data(bytes).base64EncodedString())
    }

    static let template = ##"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:">
        <title>Stroke review</title>
        <style>
        :root {
          --bg: #ffffff; --fg: #1b1f24; --muted: #5b6472; --panel: #f3f4f6; --line: #d5d9e0; --grid: #eceef2;
          --signal: #1f2937; --stroke: #2563eb; --added: #059669; --ghost: #9aa1ad; --selected: #d97706;
          --excluded: rgba(220, 38, 38, 0.15); --excluded-edge: #dc2626; --notcounted: rgba(100, 116, 139, 0.16);
          --speed: #c2410c; --viewed: #10b981; --rx: #a855f7; --ry: #0ea5e9; --rz: #65a30d; --window: rgba(37, 99, 235, 0.14);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #111318; --fg: #e6e8ec; --muted: #9aa3b2; --panel: #1b1e25; --line: #2e333d; --grid: #1f232b;
            --signal: #e5e7eb; --stroke: #60a5fa; --added: #34d399; --ghost: #6b7280; --selected: #fbbf24;
            --excluded: rgba(248, 113, 113, 0.18); --excluded-edge: #f87171; --notcounted: rgba(148, 163, 184, 0.14);
            --speed: #fb923c; --viewed: #34d399; --window: rgba(96, 165, 250, 0.18);
          }
        }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 12px 16px 32px; background: var(--bg); color: var(--fg);
          font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
        h1 { font-size: 18px; margin: 0 12px 0 0; }
        header { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 16px; margin-bottom: 8px; }
        .stats { display: flex; flex-wrap: wrap; gap: 4px 16px; color: var(--muted); font-variant-numeric: tabular-nums; }
        .stats b { color: var(--fg); font-weight: 600; }
        .bar { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; margin: 8px 0; }
        button, select, input, textarea { font: inherit; color: inherit; }
        button, select { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 4px 10px; cursor: pointer; }
        button:disabled { opacity: 0.45; cursor: default; }
        button.primary { background: var(--stroke); border-color: var(--stroke); color: #fff; }
        canvas { display: block; width: 100%; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); touch-action: none; }
        #overview { height: 96px; cursor: pointer; margin-bottom: 8px; }
        #main { height: 420px; cursor: crosshair; }
        .status { min-height: 20px; color: var(--muted); font-variant-numeric: tabular-nums; margin-top: 4px; }
        .save { margin-top: 16px; padding: 12px; background: var(--panel); border-radius: 8px; display: grid; gap: 8px; max-width: 760px; }
        .save label { display: grid; gap: 2px; }
        .save textarea { min-height: 48px; padding: 6px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); }
        .save .row { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; }
        .save .check { display: flex; gap: 8px; align-items: flex-start; }
        .note { color: var(--muted); font-size: 13px; }
        .legend { display: flex; flex-wrap: wrap; gap: 4px 14px; color: var(--muted); font-size: 13px; }
        .sw { display: inline-block; width: 12px; height: 12px; border-radius: 2px; vertical-align: -2px; margin-right: 4px; }
        details { margin-top: 12px; max-width: 760px; }
        kbd { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; padding: 1px 4px; border: 1px solid var(--line); border-radius: 4px; background: var(--panel); }
        ul { margin: 6px 0; padding-left: 20px; }
        </style>
        </head>
        <body>
        <header>
          <h1>Stroke review</h1>
          <div class="stats" id="stats"></div>
        </header>
        <div class="bar">
          <button id="prev" title="Previous page (Shift+Space)">◀ Page</button>
          <button id="next" title="Next page (Space)">Page ▶</button>
          <button id="nextUnviewed" title="Jump to the first part not yet viewed (N)">Next unviewed</button>
          <label>Window <select id="span">
            <option value="10">10 s</option><option value="20" selected>20 s</option><option value="30">30 s</option>
            <option value="60">60 s</option><option value="120">120 s</option></select></label>
          <label><input type="checkbox" id="showRotation"> Rotation x/y/z</label>
          <button id="undo" title="Undo (Ctrl/Cmd+Z)">Undo</button>
          <button id="redo" title="Redo (Shift+Ctrl/Cmd+Z)">Redo</button>
        </div>
        <canvas id="overview"></canvas>
        <canvas id="main"></canvas>
        <div class="status" id="status">&nbsp;</div>
        <div class="legend">
          <span><span class="sw" style="background:var(--stroke)"></span>stroke (detector candidate)</span>
          <span><span class="sw" style="background:var(--added)"></span>stroke added or moved by you</span>
          <span><span class="sw" style="background:var(--ghost)"></span>removed candidate (click to restore)</span>
          <span><span class="sw" style="background:var(--excluded)"></span>excluded: not paddling</span>
          <span><span class="sw" style="background:var(--notcounted)"></span>app counts no strokes here</span>
          <span><span class="sw" style="background:var(--speed)"></span>GPS speed</span>
        </div>

        <section class="save">
          <div class="row">
            <button id="saveProgress" title="Download labels.draft.json to continue later">Save progress</button>
            <label class="row">Load labels <input type="file" id="load" accept=".json,application/json"></label>
          </div>
          <label>How the truth was measured
            <select id="source">
              <option value="">Choose…</option>
              <option value="motion-review">motion-review: every stroke checked on this page</option>
              <option value="video">video: checked against video of the session</option>
              <option value="manual-count">manual-count: counted while paddling</option>
            </select>
          </label>
          <label>Description (conditions and setup: wrist, boat, water; no places, dates or names)
            <textarea id="description" maxlength="300"></textarea>
          </label>
          <label>License
            <select id="license"><option value="CC-BY-4.0">CC-BY-4.0</option><option value="CC0-1.0">CC0-1.0</option></select>
          </label>
          <label class="check"><input type="checkbox" id="confirm">
            <span>I looked at the whole session, every stroke marker is on a real stroke, every real stroke has a marker, and every stretch that is not paddling is excluded.</span>
          </label>
          <div class="row">
            <button class="primary" id="export" disabled>Export labels.json</button>
            <span class="note" id="exportNote"></span>
          </div>
        </section>

        <details open>
          <summary>How to review</summary>
          <ul>
            <li>The dark line is the wrist motion on its main axis. Each wrist cycle is one positive peak. For kayak, the other blade's stroke is the trough between peaks, so there are two markers per cycle.</li>
            <li><b>Click</b> to add a stroke at the nearest peak or trough (<kbd>Alt</kbd>+click: exactly where you click). <b>Drag</b> a marker to move it. <b>Right-click</b> a marker, or select it and press <kbd>Delete</kbd>, to remove it. Click a grey dashed line to restore a removed candidate.</li>
            <li><b>Shift+drag</b> marks a stretch that is not paddling (getting in, drifting, resting, carrying); it removes the strokes inside. Right-click it to remove it.</li>
            <li>Drag empty space or scroll to pan; <kbd>Ctrl</kbd>+scroll or <kbd>+</kbd>/<kbd>−</kbd> to zoom. <kbd>Space</kbd>/<kbd>Shift+Space</kbd>: next/previous page. <kbd>N</kbd>: next part not yet viewed. <kbd>Ctrl/Cmd+Z</kbd>: undo.</li>
            <li>Work is kept in this browser as you go. <b>Save progress</b> downloads a file you can load later; <b>Export labels.json</b> writes the reviewed ground truth.</li>
          </ul>
        </details>

        <script type="application/json" id="review-data">__REVIEW_DATA__</script>
        <script>
        "use strict";
        const D = JSON.parse(document.getElementById("review-data").textContent);
        const SPC = D.strokesPerCycle;
        const MAX_GAP = 4 / SPC;
        const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

        function decode(channel) {
          const bin = atob(channel.data);
          const out = new Float32Array(bin.length / 2);
          for (let i = 0; i < out.length; i++) {
            let v = bin.charCodeAt(2 * i) | (bin.charCodeAt(2 * i + 1) << 8);
            if (v >= 32768) v -= 65536;
            out[i] = v === -32768 ? NaN : v * channel.scale;
          }
          return out;
        }
        const SIG = { start: D.signalStart, dt: D.signalInterval };
        for (const name of Object.keys(D.channels)) SIG[name] = decode(D.channels[name]);
        const candidates = D.candidates.map((c) => ({ t: c[0], side: c[1] < 0 ? null : c[1], counted: c[2] === 1 }));

        // ---- state ----
        let strokes = [];   // {t, side}, sorted by t
        let excluded = [];  // {start, end}, sorted, disjoint
        let viewed = [];    // [a, b] merged
        let view = { t0: 0, span: 20 };
        let selected = null;
        const history = [];
        const future = [];

        function fromLabels(labels) {
          const truth = (labels && labels.truth) || {};
          strokes = (truth.strokeTimes || []).filter((s) => Number.isFinite(s.t))
            .map((s) => ({ t: s.t, side: s.side === 0 || s.side === 1 ? s.side : null }))
            .sort((a, b) => a.t - b.t);
          excluded = mergeSegments((truth.excluded || []).filter((e) => e.end > e.start).map((e) => ({ start: e.start, end: e.end })));
          if (labels) {
            const sourceSel = document.getElementById("source");
            sourceSel.value = [...sourceSel.options].some((o) => o.value === labels.source) ? labels.source : "";
            document.getElementById("description").value = labels.description || "";
            if (labels.license === "CC0-1.0" || labels.license === "CC-BY-4.0") document.getElementById("license").value = labels.license;
          }
        }
        function mergeSegments(list) {
          list.sort((a, b) => a.start - b.start);
          const out = [];
          for (const s of list) {
            const last = out[out.length - 1];
            if (last && s.start <= last.end) last.end = Math.max(last.end, s.end); else out.push({ start: s.start, end: s.end });
          }
          return out;
        }
        function snapshot() { return JSON.stringify({ strokes, excluded }); }
        function restore(text) { const s = JSON.parse(text); strokes = s.strokes; excluded = s.excluded; selected = null; }
        function remember() { history.push(snapshot()); if (history.length > 300) history.shift(); future.length = 0; }
        function undo() { if (!history.length) return; future.push(snapshot()); restore(history.pop()); changed(); }
        function redo() { if (!future.length) return; history.push(snapshot()); restore(future.pop()); changed(); }

        // ---- helpers ----
        function lowerBound(arr, t, key) {
          let lo = 0, hi = arr.length;
          while (lo < hi) { const mid = (lo + hi) >> 1; if (key(arr[mid]) < t) lo = mid + 1; else hi = mid; }
          return lo;
        }
        function nearestStroke(t) {
          const i = lowerBound(strokes, t, (s) => s.t);
          let best = null;
          for (const j of [i - 1, i]) if (j >= 0 && j < strokes.length && (!best || Math.abs(strokes[j].t - t) < Math.abs(best.t - t))) best = strokes[j];
          return best;
        }
        function isCandidate(t) {
          const i = lowerBound(candidates, t - 0.0015, (c) => c.t);
          return i < candidates.length && Math.abs(candidates[i].t - t) <= 0.0015;
        }
        function inExcluded(t) { return excluded.find((e) => t >= e.start && t <= e.end) || null; }
        function fmt(t) {
          const sign = t < 0 ? "-" : ""; t = Math.abs(t);
          const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
          const ss = s.toFixed(1).padStart(4, "0");
          return sign + (h ? h + ":" + String(m).padStart(2, "0") : String(m)) + ":" + ss;
        }
        function sigAt(name, t) {
          const i = Math.round((t - SIG.start) / SIG.dt);
          return i >= 0 && i < SIG[name].length ? SIG[name][i] : NaN;
        }
        function snap(t) {
          const v0 = sigAt("main", t);
          if (!Number.isFinite(v0)) return t;
          const sign = v0 >= 0 ? 1 : -1;
          let best = t, bestV = -Infinity;
          for (let dt = -0.2; dt <= 0.2001; dt += SIG.dt) {
            const v = sign * sigAt("main", t + dt);
            if (Number.isFinite(v) && v > bestV) { bestV = v; best = t + dt; }
          }
          const i = Math.round((best - SIG.start) / SIG.dt);
          return SIG.start + i * SIG.dt;
        }
        function strokeRate() {
          let n = 0, T = 0, bn = 0, bt = 0;
          const close = () => { if (bn >= 2) { n += bn; T += bt; } bn = 0; bt = 0; };
          for (let i = 0; i + 1 < strokes.length; i++) {
            const a = strokes[i].t, b = strokes[i + 1].t, gap = b - a;
            const split = gap <= 0 || gap > MAX_GAP || excluded.some((e) => e.start < b && e.end > a);
            if (split) close(); else { bn++; bt += gap; }
          }
          close();
          return n > 0 && T > 0 ? (60 * n) / T : null;
        }
        function addViewed(a, b) {
          a = Math.max(0, a); b = Math.min(D.duration, b);
          if (b <= a) return;
          viewed.push([a, b]);
          viewed.sort((x, y) => x[0] - y[0]);
          const out = [];
          for (const v of viewed) { const l = out[out.length - 1]; if (l && v[0] <= l[1] + 0.01) l[1] = Math.max(l[1], v[1]); else out.push([v[0], v[1]]); }
          viewed = out;
        }
        function viewedFraction() { return viewed.reduce((s, v) => s + v[1] - v[0], 0) / Math.max(1, D.duration); }

        // ---- canvases ----
        const overview = document.getElementById("overview");
        const main = document.getElementById("main");
        function fit(canvas) {
          const r = canvas.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
          const w = Math.max(1, Math.round(r.width * dpr)), h = Math.max(1, Math.round(r.height * dpr));
          if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
          const ctx = canvas.getContext("2d");
          ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
          return { ctx, w: r.width, h: r.height };
        }
        const SIGNAL_FRACTION = 0.74;
        function mainX(t, w) { return ((t - view.t0) / view.span) * w; }
        function mainT(x, w) { return view.t0 + (x / w) * view.span; }

        function shade(ctx, ranges, x, h, color, y0) {
          ctx.fillStyle = color;
          for (const r of ranges) { const a = x(r[0]), b = x(r[1]); if (b >= 0 && a <= 1e5) ctx.fillRect(a, y0 || 0, Math.max(1, b - a), h); }
        }

        function drawMain() {
          const { ctx, w, h } = fit(main);
          const t0 = view.t0, t1 = view.t0 + view.span;
          const sh = h * SIGNAL_FRACTION;
          const x = (t) => mainX(t, w);
          ctx.clearRect(0, 0, w, h);
          shade(ctx, D.notCounted, x, h, css("--notcounted"));
          shade(ctx, excluded.map((e) => [e.start, e.end]), x, h, css("--excluded"));
          if (drag && drag.kind === "exclude") {
            ctx.fillStyle = css("--excluded");
            const a = x(Math.min(drag.a, drag.b)), b = x(Math.max(drag.a, drag.b));
            ctx.fillRect(a, 0, b - a, h);
          }
          // grid
          ctx.strokeStyle = css("--grid"); ctx.fillStyle = css("--muted"); ctx.lineWidth = 1;
          ctx.font = "11px system-ui, sans-serif";
          const step = view.span <= 30 ? 1 : view.span <= 60 ? 5 : 10;
          const labelEvery = view.span <= 20 ? 2 : view.span <= 30 ? 5 : step * 2;
          for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) {
            const px = Math.round(x(t)) + 0.5;
            ctx.beginPath(); ctx.moveTo(px, 0); ctx.lineTo(px, h); ctx.stroke();
            if (Math.abs(t / labelEvery - Math.round(t / labelEvery)) < 1e-6) ctx.fillText(fmt(t).replace(/\.0$/, ""), px + 3, sh - 4);
          }
          ctx.strokeStyle = css("--line");
          ctx.beginPath(); ctx.moveTo(0, sh + 0.5); ctx.lineTo(w, sh + 0.5); ctx.stroke();
          ctx.beginPath(); ctx.moveTo(0, sh / 2 + 0.5); ctx.lineTo(w, sh / 2 + 0.5); ctx.stroke();

          // signal scale: 98th percentile of |main| in view
          const i0 = Math.max(0, Math.floor((t0 - SIG.start) / SIG.dt) - 1);
          const i1 = Math.min(SIG.main.length - 1, Math.ceil((t1 - SIG.start) / SIG.dt) + 1);
          const mags = [];
          for (let i = i0; i <= i1; i++) if (Number.isFinite(SIG.main[i])) mags.push(Math.abs(SIG.main[i]));
          mags.sort((a, b) => a - b);
          const peak = Math.max(0.2, mags.length ? mags[Math.floor(mags.length * 0.98)] * 1.15 : 1);
          const y = (v) => sh / 2 - (v / peak) * (sh / 2 - 6);
          function line(name, color, width) {
            ctx.strokeStyle = color; ctx.lineWidth = width; ctx.beginPath();
            let pen = false;
            for (let i = i0; i <= i1; i++) {
              const v = SIG[name][i];
              if (!Number.isFinite(v)) { pen = false; continue; }
              const px = x(SIG.start + i * SIG.dt), py = Math.max(1, Math.min(sh - 1, y(v)));
              if (pen) ctx.lineTo(px, py); else { ctx.moveTo(px, py); pen = true; }
            }
            ctx.stroke();
          }
          if (document.getElementById("showRotation").checked) {
            line("rx", css("--rx"), 1); line("ry", css("--ry"), 1); line("rz", css("--rz"), 1);
          }
          line("main", css("--signal"), 1.6);

          // removed candidates
          ctx.setLineDash([4, 4]); ctx.strokeStyle = css("--ghost"); ctx.lineWidth = 1;
          for (let i = lowerBound(candidates, t0 - 1, (c) => c.t); i < candidates.length && candidates[i].t <= t1 + 1; i++) {
            const c = candidates[i], near = nearestStroke(c.t);
            if (near && Math.abs(near.t - c.t) <= 0.0015) continue;
            const px = Math.round(x(c.t)) + 0.5;
            ctx.beginPath(); ctx.moveTo(px, 8); ctx.lineTo(px, sh); ctx.stroke();
          }
          ctx.setLineDash([]);

          // strokes
          for (let i = lowerBound(strokes, t0 - 1, (s) => s.t); i < strokes.length && strokes[i].t <= t1 + 1; i++) {
            const s = strokes[i], px = Math.round(x(s.t)) + 0.5;
            const color = s === selected ? css("--selected") : isCandidate(s.t) ? css("--stroke") : css("--added");
            ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = s === selected ? 2.5 : 1.5;
            ctx.beginPath(); ctx.moveTo(px, 10); ctx.lineTo(px, sh); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(px - 6, 0); ctx.lineTo(px + 6, 0); ctx.lineTo(px, 10); ctx.closePath(); ctx.fill();
            if (s.side !== null && s.side !== undefined) { ctx.font = "10px system-ui"; ctx.fillText(String(s.side), px + 4, 20); }
          }

          // speed
          const s0 = lowerBound(D.speedT, t0 - 2, (v) => v), s1 = lowerBound(D.speedT, t1 + 2, (v) => v);
          let vmax = 3;
          for (let i = s0; i < s1; i++) vmax = Math.max(vmax, D.speedV[i]);
          const sy = (v) => h - 4 - (v / vmax) * (h - sh - 14);
          ctx.strokeStyle = css("--speed"); ctx.lineWidth = 1.5; ctx.beginPath();
          let prevT = null;
          for (let i = s0; i < s1; i++) {
            const px = x(D.speedT[i]), py = sy(D.speedV[i]);
            if (prevT !== null && D.speedT[i] - prevT <= 3) ctx.lineTo(px, py); else ctx.moveTo(px, py);
            prevT = D.speedT[i];
          }
          ctx.stroke();
          ctx.fillStyle = css("--muted"); ctx.font = "11px system-ui";
          ctx.fillText("speed, m/s (0–" + vmax.toFixed(1) + ")", 4, sh + 13);
        }

        function drawOverview() {
          const { ctx, w, h } = fit(overview);
          const x = (t) => (t / D.duration) * w;
          ctx.clearRect(0, 0, w, h);
          shade(ctx, D.notCounted, x, h, css("--notcounted"));
          shade(ctx, excluded.map((e) => [e.start, e.end]), x, h, css("--excluded"));
          // labelled strokes per 10 s, as SPM bars
          const bucket = 10, n = Math.ceil(D.duration / bucket);
          const counts = new Array(n).fill(0);
          for (const s of strokes) { const b = Math.floor(s.t / bucket); if (b >= 0 && b < n) counts[b]++; }
          ctx.fillStyle = css("--stroke");
          for (let b = 0; b < n; b++) {
            if (!counts[b]) continue;
            const spm = (counts[b] * 60) / bucket, bh = Math.min(1, spm / 120) * (h * 0.45);
            ctx.globalAlpha = 0.55; ctx.fillRect(x(b * bucket), h - bh, Math.max(1, x(bucket) - 0.5), bh); ctx.globalAlpha = 1;
          }
          // speed
          let vmax = 3;
          for (const v of D.speedV) vmax = Math.max(vmax, v);
          ctx.strokeStyle = css("--speed"); ctx.lineWidth = 1; ctx.beginPath();
          let prevT = null;
          for (let i = 0; i < D.speedT.length; i++) {
            const px = x(D.speedT[i]), py = h * 0.55 - (D.speedV[i] / vmax) * (h * 0.5);
            if (prevT !== null && D.speedT[i] - prevT <= 3) ctx.lineTo(px, py); else ctx.moveTo(px, py);
            prevT = D.speedT[i];
          }
          ctx.stroke();
          // viewed
          ctx.fillStyle = css("--viewed");
          for (const v of viewed) ctx.fillRect(x(v[0]), 0, Math.max(1, x(v[1]) - x(v[0])), 4);
          // window
          ctx.fillStyle = css("--window"); ctx.strokeStyle = css("--stroke"); ctx.lineWidth = 1;
          ctx.fillRect(x(view.t0), 0, Math.max(2, x(view.span)), h);
          ctx.strokeRect(x(view.t0) + 0.5, 0.5, Math.max(2, x(view.span)) - 1, h - 1);
        }

        function updateStats() {
          const rate = strokeRate();
          const excludedTime = excluded.reduce((s, e) => s + e.end - e.start, 0);
          document.getElementById("stats").innerHTML =
            "<span>" + D.sport + "</span>" +
            "<span>strokes <b>" + strokes.length + "</b> (detector: " + candidates.length + ")</span>" +
            "<span>rate <b>" + (rate ? rate.toFixed(1) : "–") + "</b> spm</span>" +
            "<span>excluded <b>" + fmt(excludedTime).replace(/\.\d$/, "") + "</b></span>" +
            "<span>viewed <b>" + Math.round(viewedFraction() * 100) + "%</b> of " + fmt(D.duration).replace(/\.\d$/, "") + "</span>";
          document.getElementById("undo").disabled = !history.length;
          document.getElementById("redo").disabled = !future.length;
          updateExport();
        }
        function updateExport() {
          const source = document.getElementById("source").value;
          const ok = document.getElementById("confirm").checked && source !== "";
          document.getElementById("export").disabled = !ok;
          const notes = [];
          if (!source) notes.push("choose how the truth was measured");
          if (!document.getElementById("confirm").checked) notes.push("confirm the review");
          if (viewedFraction() < 0.98) notes.push("you have viewed " + Math.round(viewedFraction() * 100) + "% of the session");
          document.getElementById("exportNote").textContent = notes.join("; ");
        }
        function draw() {
          view.span = Math.max(2, Math.min(D.duration || 2, view.span));
          view.t0 = Math.max(Math.min(0, SIG.start), Math.min(D.duration - view.span, view.t0));
          addViewed(view.t0, view.t0 + view.span);
          drawMain(); drawOverview(); updateStats();
        }
        function changed() { save(); draw(); }

        // ---- persistence ----
        const KEY = "stroke-review:" + D.reviewKey;
        function save() {
          try {
            localStorage.setItem(KEY, JSON.stringify({
              strokes, excluded, viewed, view,
              source: document.getElementById("source").value,
              description: document.getElementById("description").value,
              license: document.getElementById("license").value,
            }));
          } catch (e) { /* storage unavailable: work stays in this tab */ }
        }
        function resume() {
          let saved = null;
          try { saved = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) { saved = null; }
          if (!saved || !Array.isArray(saved.strokes)) return false;
          if (!confirm("Resume the review saved in this browser (" + saved.strokes.length + " strokes)?")) return false;
          strokes = saved.strokes; excluded = saved.excluded || []; viewed = saved.viewed || [];
          if (saved.view) view = saved.view;
          document.getElementById("source").value = saved.source || "";
          document.getElementById("description").value = saved.description || "";
          document.getElementById("license").value = saved.license || "CC-BY-4.0";
          return true;
        }
        function labelsFile(source) {
          const strokeTimes = strokes.map((s) => {
            const o = { t: Math.round(s.t * 1000) / 1000 };
            if (s.side === 0 || s.side === 1) o.side = s.side;
            return o;
          });
          return {
            v: 1, sport: D.sport, source,
            description: document.getElementById("description").value.trim(),
            license: document.getElementById("license").value,
            truth: {
              strokeTimes,
              excluded: excluded.map((e) => ({ start: Math.round(e.start * 1000) / 1000, end: Math.round(e.end * 1000) / 1000 })),
            },
          };
        }
        function download(name, object) {
          const blob = new Blob([JSON.stringify(object, null, 2) + "\n"], { type: "application/json" });
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob); a.download = name;
          document.body.appendChild(a); a.click(); a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 1000);
        }

        // ---- interaction ----
        let drag = null;
        function hitStroke(t, w) {
          const s = nearestStroke(t);
          return s && Math.abs(mainX(s.t, w) - mainX(t, w)) <= 7 ? s : null;
        }
        function hitGhost(t, w) {
          let best = null;
          for (let i = lowerBound(candidates, t - 1, (c) => c.t); i < candidates.length && candidates[i].t <= t + 1; i++) {
            const c = candidates[i], near = nearestStroke(c.t);
            if (near && Math.abs(near.t - c.t) <= 0.0015) continue;
            if (Math.abs(mainX(c.t, w) - mainX(t, w)) <= 6 && (!best || Math.abs(c.t - t) < Math.abs(best.t - t))) best = c;
          }
          return best;
        }
        function eventT(e) {
          const r = main.getBoundingClientRect();
          return { t: mainT(e.clientX - r.left, r.width), w: r.width, x: e.clientX - r.left };
        }
        function insertStroke(s) { strokes.splice(lowerBound(strokes, s.t, (v) => v.t), 0, s); }
        function removeStroke(s) { const i = strokes.indexOf(s); if (i >= 0) strokes.splice(i, 1); if (selected === s) selected = null; }

        main.addEventListener("pointerdown", (e) => {
          if (e.button !== 0) return;
          main.setPointerCapture(e.pointerId);
          const { t, w, x } = eventT(e);
          if (e.shiftKey) { drag = { kind: "exclude", a: t, b: t }; return; }
          const s = hitStroke(t, w);
          if (s) { selected = s; drag = { kind: "stroke", stroke: s, moved: false, x0: x, before: snapshot() }; draw(); return; }
          drag = { kind: "pan", x0: x, t0: view.t0, moved: false, alt: e.altKey };
        });
        main.addEventListener("pointermove", (e) => {
          const { t, w, x } = eventT(e);
          document.getElementById("status").textContent = fmt(t) + (inExcluded(t) ? "  (excluded)" : "") +
            (selected ? "   selected stroke at " + fmt(selected.t) : "");
          if (!drag) return;
          if (drag.kind === "exclude") { drag.b = t; drawMain(); return; }
          if (Math.abs(x - drag.x0) < 3 && !drag.moved) return;
          drag.moved = true;
          if (drag.kind === "stroke") {
            drag.stroke.t = Math.max(0, Math.min(D.duration, t));
            strokes.sort((a, b) => a.t - b.t);
            drawMain();
          } else if (drag.kind === "pan") {
            view.t0 = drag.t0 - ((x - drag.x0) / w) * view.span;
            draw();
          }
        });
        main.addEventListener("pointerup", (e) => {
          if (!drag) return;
          const d = drag; drag = null;
          const { t, w } = eventT(e);
          if (d.kind === "exclude") {
            d.b = t;
            const a = Math.max(0, Math.min(d.a, d.b)), b = Math.min(D.duration, Math.max(d.a, d.b));
            if (b - a >= 0.2) {
              remember();
              excluded = mergeSegments(excluded.concat([{ start: a, end: b }]));
              strokes = strokes.filter((s) => !inExcluded(s.t));
              if (selected && !strokes.includes(selected)) selected = null;
              changed();
            } else draw();
          } else if (d.kind === "stroke") {
            if (d.moved) { history.push(d.before); future.length = 0; changed(); } else draw();
          } else if (d.kind === "pan" && !d.moved) {
            const ghost = hitGhost(t, w);
            remember();
            if (ghost) { insertStroke({ t: ghost.t, side: ghost.side }); }
            else {
              const at = d.alt ? t : snap(t);
              if (inExcluded(at)) { history.pop(); document.getElementById("status").textContent = "That time is excluded; right-click the excluded stretch to remove it first."; return; }
              const near = nearestStroke(at);
              if (near && Math.abs(near.t - at) < 0.05) { history.pop(); selected = near; draw(); return; }
              const prev = nearestStroke(at);
              const side = SPC === 1 && prev ? prev.side : null;
              const s = { t: at, side };
              insertStroke(s); selected = s;
            }
            changed();
          }
        });
        main.addEventListener("contextmenu", (e) => {
          e.preventDefault();
          const { t, w } = eventT(e);
          const s = hitStroke(t, w);
          if (s) { remember(); removeStroke(s); changed(); return; }
          const seg = inExcluded(t);
          if (seg) { remember(); excluded = excluded.filter((x) => x !== seg); changed(); }
        });
        main.addEventListener("wheel", (e) => {
          e.preventDefault();
          const { t } = eventT(e);
          if (e.ctrlKey || e.metaKey) {
            const factor = Math.exp(e.deltaY * 0.002);
            const span = Math.max(2, Math.min(600, view.span * factor));
            view.t0 = t - ((t - view.t0) / view.span) * span; view.span = span;
          } else {
            const delta = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
            view.t0 += (delta / main.getBoundingClientRect().width) * view.span;
          }
          syncSpan(); draw();
        }, { passive: false });

        let overviewDrag = false;
        function overviewJump(e) {
          const r = overview.getBoundingClientRect();
          view.t0 = ((e.clientX - r.left) / r.width) * D.duration - view.span / 2;
          draw();
        }
        overview.addEventListener("pointerdown", (e) => { overviewDrag = true; overview.setPointerCapture(e.pointerId); overviewJump(e); });
        overview.addEventListener("pointermove", (e) => { if (overviewDrag) overviewJump(e); });
        overview.addEventListener("pointerup", () => { overviewDrag = false; });

        function page(direction) { view.t0 += direction * view.span * 0.9; draw(); }
        function nextUnviewed() {
          let t = 0;
          for (const v of viewed) { if (v[0] > t + 0.5) break; t = Math.max(t, v[1]); }
          if (t >= D.duration - 0.5) { document.getElementById("status").textContent = "You have viewed the whole session."; return; }
          view.t0 = Math.max(0, t - view.span * 0.1); draw();
        }
        function zoom(factor) {
          const c = view.t0 + view.span / 2;
          view.span = Math.max(2, Math.min(600, view.span * factor)); view.t0 = c - view.span / 2; syncSpan(); draw();
        }
        function syncSpan() {
          const sel = document.getElementById("span");
          const match = [...sel.options].find((o) => Math.abs(Number(o.value) - view.span) < 0.5);
          sel.value = match ? match.value : "";
        }
        document.getElementById("span").addEventListener("change", (e) => {
          const c = view.t0 + view.span / 2; view.span = Number(e.target.value); view.t0 = c - view.span / 2; draw();
        });
        document.getElementById("prev").onclick = () => page(-1);
        document.getElementById("next").onclick = () => page(1);
        document.getElementById("nextUnviewed").onclick = nextUnviewed;
        document.getElementById("undo").onclick = undo;
        document.getElementById("redo").onclick = redo;
        document.getElementById("showRotation").onchange = draw;
        for (const id of ["source", "description", "license", "confirm"]) {
          document.getElementById(id).addEventListener("input", () => { save(); updateExport(); });
          document.getElementById(id).addEventListener("change", () => { save(); updateExport(); });
        }
        document.getElementById("saveProgress").onclick = () => download("labels.draft.json", labelsFile("draft"));
        document.getElementById("export").onclick = () => {
          const source = document.getElementById("source").value;
          if (!source || !document.getElementById("confirm").checked) return;
          if (viewedFraction() < 0.98 && !confirm("You have viewed " + Math.round(viewedFraction() * 100) + "% of the session. Export anyway?")) return;
          download("labels.json", labelsFile(source));
        };
        document.getElementById("load").addEventListener("change", async (e) => {
          const file = e.target.files && e.target.files[0];
          if (!file) return;
          try {
            const labels = JSON.parse(await file.text());
            if (!labels.truth || !Array.isArray(labels.truth.strokeTimes)) throw new Error("no truth.strokeTimes");
            if (labels.sport && labels.sport !== D.sport) throw new Error("sport " + labels.sport + " does not match " + D.sport);
            remember(); fromLabels(labels); changed();
            document.getElementById("status").textContent = "Loaded " + strokes.length + " strokes from " + file.name + ".";
          } catch (err) {
            alert("Could not load labels: " + err.message);
          }
          e.target.value = "";
        });
        window.addEventListener("keydown", (e) => {
          const tag = (e.target && e.target.tagName) || "";
          if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
          const mod = e.ctrlKey || e.metaKey;
          if (mod && e.key.toLowerCase() === "z") { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
          if (mod && e.key.toLowerCase() === "y") { e.preventDefault(); redo(); return; }
          if (mod) return;
          switch (e.key) {
            case " ": e.preventDefault(); page(e.shiftKey ? -1 : 1); break;
            case "ArrowRight": case "d": e.preventDefault(); view.t0 += view.span * 0.5; draw(); break;
            case "ArrowLeft": case "a": e.preventDefault(); view.t0 -= view.span * 0.5; draw(); break;
            case "+": case "=": zoom(1 / 1.5); break;
            case "-": case "_": zoom(1.5); break;
            case "n": case "N": nextUnviewed(); break;
            case "Delete": case "Backspace":
              if (selected) { e.preventDefault(); remember(); removeStroke(selected); changed(); }
              break;
            case "Escape": selected = null; draw(); break;
          }
        });
        window.addEventListener("resize", draw);

        fromLabels(D.labels);
        const resumed = resume();
        if (!resumed && strokes.length) view.t0 = Math.max(0, strokes[0].t - 2);
        const jump = /(?:^|[#&])t=([0-9.]+)/.exec(location.hash);
        if (jump) view.t0 = Number(jump[1]);
        syncSpan();
        draw();
        if (!resumed) save();
        </script>
        </body>
        </html>

        """##
}
