import SwiftUI
import WaterKit

/// A small animated seascape for the conditions: the sky, sun or moon, clouds, rain,
/// snow, fog and lightning; waves, whitecaps and wind streaks that grow with the wind;
/// and a sailboat whose rig shows the wind: slack sails in a calm, full in a
/// breeze, reefed when it's strong, furled when it's too much. Kept to a few bold shapes
/// so it reads at card size. Still with Reduce Motion. Decorative: the card around it
/// carries the words.
///
/// Everything moves with the wind (clouds, rain, snow, streaks, waves, whitecaps), and the
/// boat runs before it: bow downwind, wake trailing upwind, pennant
/// streaming ahead. See ``SceneWind``. It sits level on flat water and rocks only as
/// much as the waves move it (``BoatMotion``).
struct WeatherScene: View {
    let weather: WeatherNow
    let outlook: WaterOutlook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t =
                reduceMotion ? 1.3 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3_600)
            Canvas { canvas, size in
                SceneDrawing(weather: weather, outlook: outlook, size: size, t: t).draw(in: &canvas)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The drawing for one frame at time `t` (seconds).
private struct SceneDrawing {
    let weather: WeatherNow
    let outlook: WaterOutlook
    let size: CGSize
    let t: Double

    private var w: Double { size.width }
    private var h: Double { size.height }
    private var horizon: Double { h * 0.66 }
    private var night: Bool { !weather.isDay }
    private var sky: WaterOutlook.Sky { outlook.sky }
    private var mood: WaterOutlook.Mood { outlook.mood }
    /// 0 calm … 1 at 14 m/s, a bit more beyond.
    private var windiness: Double { min(weather.windSpeed / 14, 1.3) }
    private var wind: SceneWind { SceneWind(windFrom: weather.windFrom) }
    /// +1 when the wind blows left to right on screen (from the west), −1 the other way.
    private var windSign: Double { wind.sign }
    private var stormy: Bool { sky == .thunderstorm }
    private var wet: Bool { [.rain, .drizzle, .thunderstorm, .snow].contains(sky) }

    func draw(in context: inout GraphicsContext) {
        drawSky(&context)
        if mood == .stormComing { drawStormBank(&context) }
        if night { drawStars(&context) }
        // Drifting clouds pass behind the sun or moon, so it never disappears.
        drawClouds(&context)
        if showsSun { night ? drawMoon(&context) : drawSun(&context) }
        if sky == .partlyCloudy, mood != .stormComing { drawParkedCloud(&context) }
        if stormy || mood == .stormComing { drawLightning(&context) }
        if windiness > 0.28 { drawWindStreaks(&context) }
        drawWater(&context)
        drawBoat(&context)
        if sky == .rain || sky == .drizzle || sky == .thunderstorm { drawRain(&context) }
        if sky == .snow { drawSnow(&context) }
        if sky == .fog { drawFog(&context) }
    }

    // MARK: Sky

    private var showsSun: Bool {
        [.clear, .partlyCloudy].contains(sky) && mood != .stormComing
    }

    private var skyColors: [Color] {
        if night {
            return stormy
                ? [rgb(0.05, 0.05, 0.13), rgb(0.12, 0.11, 0.22)]
                : [rgb(0.03, 0.07, 0.2), rgb(0.1, 0.2, 0.38)]
        }
        switch sky {
        case .clear, .partlyCloudy: return [rgb(0.16, 0.5, 0.82), rgb(0.5, 0.78, 0.93)]
        case .overcast: return [rgb(0.36, 0.45, 0.55), rgb(0.6, 0.67, 0.73)]
        case .drizzle: return [rgb(0.34, 0.42, 0.5), rgb(0.55, 0.62, 0.68)]
        case .rain: return [rgb(0.22, 0.3, 0.4), rgb(0.42, 0.5, 0.58)]
        case .thunderstorm: return [rgb(0.14, 0.13, 0.26), rgb(0.32, 0.3, 0.42)]
        case .snow: return [rgb(0.5, 0.58, 0.68), rgb(0.78, 0.83, 0.88)]
        case .fog: return [rgb(0.55, 0.6, 0.64), rgb(0.78, 0.8, 0.82)]
        }
    }

    private func drawSky(_ context: inout GraphicsContext) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: skyColors), startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
        // Thunder: a low, dark ceiling of cloud across the top, where the bolts come from.
        if stormy {
            context.fill(
                Path(CGRect(x: 0, y: 0, width: w, height: h * 0.4)),
                with: .linearGradient(
                    Gradient(colors: [rgb(0.08, 0.07, 0.15).opacity(0.85), .clear]), startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: h * 0.4)))
        }
        // A warm glow low on a sunny horizon.
        if !night, showsSun {
            context.fill(
                Path(CGRect(x: 0, y: horizon - h * 0.25, width: w, height: h * 0.25)),
                with: .linearGradient(
                    Gradient(colors: [.clear, rgb(1, 0.86, 0.6).opacity(0.25)]),
                    startPoint: CGPoint(x: 0, y: horizon - h * 0.25), endPoint: CGPoint(x: 0, y: horizon)))
        }
    }

    /// A wall of dark cloud building on the horizon, on the right where the eye goes
    /// (the words sit on the left).
    private func drawStormBank(_ context: inout GraphicsContext) {
        context.fill(
            Path(CGRect(origin: .zero, size: CGSize(width: w, height: horizon))),
            with: .linearGradient(
                Gradient(colors: [.clear, rgb(0.12, 0.1, 0.22).opacity(0.75)]),
                startPoint: CGPoint(x: w * 0.45, y: 0), endPoint: CGPoint(x: w, y: 0)))
        let creep = sin(t * 0.4) * 4
        for i in 0..<3 {
            let x = w * (0.97 - Double(i) * 0.12) + creep
            let r = h * (0.17 - Double(i) * 0.03)
            cloud(&context, center: CGPoint(x: x, y: horizon - r * 0.7), scale: r / 20, color: rgb(0.2, 0.18, 0.3))
        }
    }

    private func drawStars(_ context: inout GraphicsContext) {
        for i in 0..<7 {
            let x = w * (0.32 + Double(i) * 0.075 + (hash(i, 1) - 0.5) * 0.05)
            let y = horizon * (0.15 + hash(i, 2) * 0.6)
            let twinkle = 0.6 + 0.4 * (0.5 + 0.5 * sin(t * (0.8 + hash(i, 3)) + Double(i)))
            let r = 1.4 + hash(i, 4) * 0.8
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(twinkle * (wet ? 0.3 : 0.9))))
        }
    }

    private var sunCenter: CGPoint { CGPoint(x: w * 0.9, y: h * 0.26) }

    /// The sun: a warm disc and a slowly turning ring of rays.
    private func drawSun(_ context: inout GraphicsContext) {
        let c = sunCenter
        let r = h * 0.12
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r * 2.4, y: c.y - r * 2.4, width: r * 4.8, height: r * 4.8)),
            with: .radialGradient(
                Gradient(colors: [rgb(1, 0.92, 0.55).opacity(0.5), .clear]), center: c, startRadius: r * 0.8,
                endRadius: r * 2.4))
        var rays = Path()
        for i in 0..<8 {
            let a = Double(i) / 8 * 2 * .pi + t * 0.15
            rays.move(to: CGPoint(x: c.x + cos(a) * r * 1.35, y: c.y + sin(a) * r * 1.35))
            rays.addLine(to: CGPoint(x: c.x + cos(a) * r * 1.75, y: c.y + sin(a) * r * 1.75))
        }
        context.stroke(rays, with: .color(rgb(1, 0.85, 0.35)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .linearGradient(
                Gradient(colors: [rgb(1, 0.92, 0.45), rgb(1, 0.74, 0.25)]), startPoint: CGPoint(x: c.x, y: c.y - r),
                endPoint: CGPoint(x: c.x, y: c.y + r)))
    }

    /// A crescent moon with a soft glow.
    private func drawMoon(_ context: inout GraphicsContext) {
        let c = sunCenter
        let r = h * 0.11
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r * 2.2, y: c.y - r * 2.2, width: r * 4.4, height: r * 4.4)),
            with: .radialGradient(
                Gradient(colors: [rgb(0.85, 0.9, 1).opacity(0.25), .clear]), center: c, startRadius: r,
                endRadius: r * 2.2))
        var moon = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        moon = moon.subtracting(
            Path(ellipseIn: CGRect(x: c.x - r * 0.35, y: c.y - r * 1.15, width: r * 2, height: r * 2)))
        context.fill(moon, with: .color(rgb(0.96, 0.94, 0.82)))
    }

    // MARK: Clouds

    private var cloudCount: Int {
        // A storm coming owns the right of the sky; no fair-weather clouds in front of it.
        if mood == .stormComing { return 0 }
        switch sky {
        case .clear: return 0
        case .partlyCloudy: return 1
        case .thunderstorm: return 2
        case .overcast, .rain, .drizzle, .snow: return 3
        case .fog: return 1
        }
    }

    private var cloudColor: Color {
        switch sky {
        case .clear, .partlyCloudy: return night ? rgb(0.55, 0.6, 0.72) : .white
        case .overcast: return rgb(0.85, 0.88, 0.92)
        case .drizzle, .fog: return rgb(0.78, 0.81, 0.85)
        case .snow: return rgb(0.93, 0.95, 0.97)
        case .rain: return rgb(0.55, 0.6, 0.68)
        case .thunderstorm: return rgb(0.18, 0.17, 0.27)
        }
    }

    private func drawClouds(_ context: inout GraphicsContext) {
        let speed = 5 + weather.windSpeed * 2.4
        let span = w + 140
        for i in 0..<cloudCount {
            let scale = stormy ? (1.15 + hash(i, 7) * 0.25) * 1.15 : 1 + hash(i, 7) * 0.4 + (wet ? 0.25 : 0)
            let base = hash(i, 8) * span + Double(i) * span / Double(max(cloudCount, 1))
            var x = (base + t * speed * windSign * (0.7 + hash(i, 9) * 0.6)).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            x -= 70
            var y = h * (0.12 + hash(i, 10) * 0.28) + (wet ? -h * 0.04 : 0)
            // Big storm clouds sit low enough that their tops stay on the card.
            if stormy { y = max(h * 0.3, 21 * scale + 4) }
            // Clouds fade as they drift behind the words on the left.
            var layer = context
            layer.opacity = 0.15 + 0.85 * smoothstep(w * 0.3, w * 0.62, x)
            cloud(&layer, center: CGPoint(x: x, y: y), scale: scale, color: cloudColor)
        }
    }

    /// Partly cloudy: one small cloud lingers in front of the sun's lower-left, inside the card.
    private func drawParkedCloud(_ context: inout GraphicsContext) {
        let parked = CGPoint(x: w * 0.875 + sin(t * 0.2) * 2, y: h * 0.38)
        cloud(&context, center: parked, scale: 0.65, color: cloudColor)
    }

    /// A puffy cloud about 64 × 30 points at `scale` 1.
    private func cloud(_ context: inout GraphicsContext, center c: CGPoint, scale s: Double, color: Color) {
        var path = Path()
        let puffs: [(Double, Double, Double)] = [(-20, 4, 12), (-6, -6, 15), (12, -2, 13), (24, 6, 9)]
        for (dx, dy, r) in puffs {
            path.addEllipse(
                in: CGRect(x: c.x + (dx - r) * s, y: c.y + (dy - r) * s, width: r * 2 * s, height: r * 2 * s))
        }
        path.addRoundedRect(
            in: CGRect(x: c.x - 30 * s, y: c.y + 2 * s, width: 62 * s, height: 13 * s),
            cornerSize: CGSize(width: 6.5 * s, height: 6.5 * s))
        context.fill(path, with: .color(color))
    }

    // MARK: Weather

    private func drawRain(_ context: inout GraphicsContext) {
        let count = sky == .drizzle ? 24 : sky == .thunderstorm ? 30 : 22
        let length = sky == .drizzle ? 10.0 : 16
        let slant = windSign * min(windiness, 1) * 0.45
        let fall = horizon + 10
        var drops = Path()
        for i in 0..<count {
            let speed = (sky == .drizzle ? 120 : 260) + hash(i, 11) * 80
            let travelled = hash(i, 12) * fall + t * speed
            let y = travelled.truncatingRemainder(dividingBy: fall)
            // Each fall starts from a fresh spot, mostly over the scene on the right where
            // drops show; a drop never jumps sideways mid-fall, it just slants off the edge.
            let cycle = Int(travelled / fall) & 0xFFFF
            let x = w * 0.3 - 20 + hash(i &+ cycle &* 97, 13) * (w * 0.7 + 40) + slant * y
            drops.move(to: CGPoint(x: x, y: y))
            drops.addLine(to: CGPoint(x: x - slant * length, y: y - length))
        }
        context.stroke(
            drops, with: fadingOverWords(opacity: sky == .drizzle ? 0.75 : 0.6, under: 0.25),
            style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawSnow(_ context: inout GraphicsContext) {
        for i in 0..<16 {
            let fall = h + 10
            let speed = 14 + hash(i, 17) * 22
            let y = (hash(i, 18) * fall + t * speed).truncatingRemainder(dividingBy: fall) - 5
            var x = hash(i, 19) * w + sin(t * 1.3 + Double(i)) * 7 + t * windSign * weather.windSpeed * 1.5
            x = x.truncatingRemainder(dividingBy: w + 40)
            if x < 0 { x += w + 40 }
            x -= 20
            let r = 2.2 + hash(i, 20) * 1.2
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.9 * (0.25 + 0.75 * smoothstep(w * 0.3, w * 0.6, x)))))
        }
    }

    private func drawFog(_ context: inout GraphicsContext) {
        var context = context
        context.addFilter(.blur(radius: h * 0.04))
        for i in 0..<3 {
            let y = h * (0.32 + Double(i) * 0.2)
            let drift = sin(t * 0.15 + Double(i) * 1.7) * w * 0.12
            let band = CGRect(x: -w * 0.3 + drift, y: y, width: w * 1.6, height: h * 0.14)
            context.fill(
                Path(roundedRect: band, cornerRadius: h * 0.07),
                with: .color(rgb(0.9, 0.92, 0.94).opacity(0.42 + 0.08 * sin(t * 0.5 + Double(i)))))
        }
    }

    /// Now and then a bolt and one soft flash that fades out; far off and faint when only
    /// coming. Never a strobe.
    private func drawLightning(_ context: inout GraphicsContext) {
        let distant = !stormy
        let period = distant ? 8.0 : 7.0
        let cycle = floor(t / period)
        let phase = t - cycle * period
        guard phase < 0.6 else { return }
        if !distant {
            context.fill(
                Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.18 * exp(-phase / 0.18))))
        }
        guard phase < 0.15 else { return }
        let seed = Int(cycle) & 0xFFFF
        // Far off it strikes inside the storm bank behind the stern; near, it stays well
        // clear of the boat.
        let x0 = distant ? w * (0.88 + hash(seed, 21) * 0.07) : w * (0.42 + hash(seed, 21) * 0.14)
        let top = distant ? horizon - h * 0.32 : 0
        let bottom = horizon
        var bolt = Path()
        bolt.move(to: CGPoint(x: x0, y: top))
        var x = x0
        let steps = 4
        for step in 1...steps {
            x += (hash(seed + step, 22) - 0.5) * (distant ? 10 : 12)
            bolt.addLine(to: CGPoint(x: x, y: top + (bottom - top) * Double(step) / Double(steps)))
        }
        context.stroke(
            bolt, with: .color(rgb(1, 0.95, 0.6).opacity(distant ? 0.9 : 1)),
            style: StrokeStyle(lineWidth: distant ? 2.2 : 2.6, lineCap: .round, lineJoin: .round))
    }

    /// Long, gently bowed gust lines, more and faster as the wind rises.
    private func drawWindStreaks(_ context: inout GraphicsContext) {
        let count = Int(1 + windiness * 3)
        let speed = 90 + windiness * 140
        for i in 0..<count {
            let length = 60 + hash(i, 23) * 40
            let travel = w + length * 2
            let progress = ((t * speed / travel) + hash(i, 24)).truncatingRemainder(dividingBy: 1)
            let head = windSign > 0 ? -length + progress * travel : w + length - progress * travel
            let y = h * (0.18 + Double(i) * 0.1 + hash(i, 25) * 0.06)
            let alpha = sin(progress * .pi) * 0.5
            let tail = head - windSign * length
            var path = Path()
            path.move(to: CGPoint(x: tail, y: y))
            path.addQuadCurve(to: CGPoint(x: head, y: y), control: CGPoint(x: (tail + head) / 2, y: y - 5))
            context.stroke(
                path, with: fadingOverWords(opacity: alpha), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    /// White that fades to `under` × `opacity` behind the words on the left of the card.
    private func fadingOverWords(opacity: Double, under: Double = 0) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(colors: [.white.opacity(opacity * under), .white.opacity(opacity)]),
            startPoint: CGPoint(x: w * 0.3, y: 0), endPoint: CGPoint(x: w * 0.6, y: 0))
    }

    // MARK: Water

    private var amplitude: Double { outlook.wind == .calm ? 0.8 : 1.8 + windiness * 7 }

    private func waveY(_ x: Double, layer: Double) -> Double {
        let k = (0.045 + windiness * 0.02) * (1 + layer * 0.35)
        let omega = (1.1 + windiness * 2.2) * windSign
        let a = amplitude * (1 - layer * 0.35)
        return horizon + layer * h * 0.09 + a * sin(k * x - omega * t + layer * 1.9)
            + a * 0.35 * sin(2.3 * k * x - 1.7 * omega * t + layer)
    }

    private var waterColors: [Color] {
        if night { return [rgb(0.05, 0.14, 0.28), rgb(0.02, 0.07, 0.15)] }
        switch sky {
        case .clear, .partlyCloudy: return [rgb(0.1, 0.5, 0.64), rgb(0.03, 0.3, 0.45)]
        case .thunderstorm: return [rgb(0.14, 0.2, 0.3), rgb(0.06, 0.1, 0.18)]
        case .rain: return [rgb(0.17, 0.32, 0.42), rgb(0.08, 0.19, 0.28)]
        case .overcast, .drizzle, .fog, .snow: return [rgb(0.22, 0.4, 0.5), rgb(0.1, 0.25, 0.35)]
        }
    }

    private func drawWater(_ context: inout GraphicsContext) {
        let colors = waterColors
        for layer in [0.0, 1.5] {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            var x = 0.0
            while x <= w + 4 {
                path.addLine(to: CGPoint(x: x, y: waveY(x, layer: layer)))
                x += 4
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            let shade = layer / 1.5
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: colors), startPoint: CGPoint(x: 0, y: horizon),
                    endPoint: CGPoint(x: 0, y: h + (1 - shade) * h * 0.4)))
            if layer == 0 {
                context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
        }
        if !night, showsSun, outlook.wind <= .light { drawGlitter(&context) }
        if outlook.wind >= .fresh { drawWhitecaps(&context) }
    }

    /// The sun's path on calm water: one soft column of light under the sun, widening
    /// toward the viewer and shimmering gently.
    private func drawGlitter(_ context: inout GraphicsContext) {
        var glow = context
        glow.addFilter(.blur(radius: 3))
        glow.opacity = 0.75 + 0.15 * sin(t * 1.2)
        let x = sunCenter.x
        let top = horizon + 1
        var column = Path()
        column.move(to: CGPoint(x: x - 7, y: top))
        column.addLine(to: CGPoint(x: x + 7, y: top))
        column.addLine(to: CGPoint(x: x + 18, y: h))
        column.addLine(to: CGPoint(x: x - 18, y: h))
        column.closeSubpath()
        glow.fill(
            column,
            with: .linearGradient(
                Gradient(colors: [rgb(1, 0.97, 0.82).opacity(0.9), rgb(1, 0.97, 0.82).opacity(0)]),
                startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: h)))
    }

    private func drawWhitecaps(_ context: inout GraphicsContext) {
        let count = outlook.wind >= .strong ? 6 : 4
        let speed = 30 + windiness * 30
        for i in 0..<count {
            let layer = Double(i % 2) * 1.5
            let life = 2.8
            let phase = (t / life + hash(i, 28)).truncatingRemainder(dividingBy: 1)
            var x = (hash(i, 29) * (w + 40) + t * speed * windSign).truncatingRemainder(dividingBy: w + 40)
            if x < 0 { x += w + 40 }
            x -= 20
            let y = waveY(x, layer: layer)
            let widthNow = (14 + hash(i, 30) * 8) * sin(phase * .pi)
            var cap = Path()
            cap.move(to: CGPoint(x: x - widthNow / 2, y: y + 1))
            cap.addQuadCurve(to: CGPoint(x: x + widthNow / 2, y: y + 1), control: CGPoint(x: x, y: y - 4))
            context.stroke(
                cap, with: .color(.white.opacity(0.8 * sin(phase * .pi))),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    // MARK: Boat

    /// How the boat is rigged for the conditions, so the wind reads at a glance.
    private enum Rig {
        /// No wind: sails hang slack, the pennant droops, a reflection on flat water.
        case slack
        /// Sails drawing.
        case drawing
        /// Sails full and taut, a wake.
        case powered
        /// Main reefed down, a longer wake.
        case reefed
        /// Too windy or thunder: sails furled.
        case furled
    }

    private var rig: Rig {
        if stormy || mood == .tooWindy || outlook.wind == .gale { return .furled }
        switch outlook.wind {
        case .calm: return .slack
        case .light: return .drawing
        case .moderate, .fresh: return mood == .stormComing ? .reefed : .powered
        case .strong, .gale: return .reefed
        }
    }

    private var boatScale: Double { h * 0.42 }
    private var boatX: Double { w * 0.78 }

    /// Where the boat floats this frame: its waterline and its on-screen angle (clockwise
    /// positive). It rides the swell averaged over the hull (both ends and the middle), so
    /// the short ripples don't jostle it, and tilts only with the waves.
    private func boatPose() -> (waterline: Double, y: Double, angle: Double) {
        let s = boatScale
        let x = boatX
        let left = waveY(x - s * 0.45, layer: 0)
        let right = waveY(x + s * 0.45, layer: 0)
        let swell = (left + 2 * waveY(x, layer: 0) + right) / 4
        // Follow most of the swell's rise and fall, less of it as the sea builds.
        let waterline = horizon + (swell - horizon) * 0.7 / (1 + 0.6 * windiness)
        let sea = outlook.wind == .calm ? 0 : min(windiness, 1)
        let angle = BoatMotion.angle(slope: (right - left) / (s * 0.9), sea: sea, t: t)
        let bob = rig == .slack ? sin(t * 0.7) * 0.5 : 0
        return (waterline, waterline + s * 0.06 + bob, angle)
    }

    private func drawBoat(_ context: inout GraphicsContext) {
        let s = boatScale
        let x = boatX
        let pose = boatPose()

        if rig == .powered || rig == .reefed { drawWake(&context, x: x, y: pose.waterline, s: s) }
        if rig == .slack { drawReflection(&context, x: x, y: pose.waterline, s: s) }

        var boat = context
        boat.concatenate(wind.boatTransform(at: CGPoint(x: x, y: pose.y), angle: pose.angle))
        if sky == .fog { boat.opacity = 0.7 }
        drawBoatShape(&boat, s: s)
    }

    /// Mast, boom, sails for the rig, pennant and hull, in the boat's own frame (origin at
    /// the waterline amidships, bow to the left); ``SceneWind/boatTransform(at:angle:)``
    /// turns it to face downwind.
    private func drawBoatShape(_ boat: inout GraphicsContext, s: Double) {
        let wood = rgb(0.32, 0.26, 0.22)
        let sailColor = Theme.pearl
        let masthead = CGPoint(x: 0, y: -s * 1.02)
        let gooseneck = CGPoint(x: 0, y: -s * 0.16)
        // The boom swings out to leeward when the sail draws; centred when slack or furled.
        let boomEnd = CGPoint(x: s * 0.5, y: rig == .slack || rig == .furled ? -s * 0.16 : -s * 0.2)

        boat.stroke(
            Path {
                $0.move(to: CGPoint(x: 0, y: -s * 0.08)); $0.addLine(to: masthead)
            },
            with: .color(wood), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        switch rig {
        case .slack:
            // Hanging limp: the leech sags in, stirring a little.
            let stir = sin(t * 1.8) * s * 0.015
            var main = Path()
            main.move(to: CGPoint(x: s * 0.03, y: -s * 0.98))
            main.addQuadCurve(to: CGPoint(x: s * 0.42 + stir, y: -s * 0.18), control: CGPoint(x: s * 0.1, y: -s * 0.5))
            main.addLine(to: CGPoint(x: s * 0.03, y: -s * 0.18))
            main.closeSubpath()
            boat.fill(main, with: .color(sailColor.opacity(0.92)))
            // The jib's leech sags in toward the forestay.
            boat.fill(jib(s: s, furl: 0, roach: -0.07 - stir / s), with: .color(rgb(0.9, 0.93, 0.92).opacity(0.92)))

        case .drawing, .powered, .reefed:
            // Taut sails: the more wind, the deeper the curve.
            let belly = rig == .drawing ? 0.08 : rig == .powered ? 0.2 : 0.16
            let head = rig == .reefed ? -s * 0.66 : -s * 0.98
            let flutter = rig == .drawing ? sin(t * 2.4) * s * 0.01 : 0
            var main = Path()
            main.move(to: CGPoint(x: s * 0.03, y: head))
            main.addQuadCurve(
                to: CGPoint(x: boomEnd.x + flutter, y: boomEnd.y),
                control: CGPoint(x: s * (0.26 + belly), y: head * 0.55))
            main.addLine(to: CGPoint(x: s * 0.03, y: gooseneck.y))
            main.closeSubpath()
            boat.fill(
                main,
                with: .linearGradient(
                    Gradient(colors: [sailColor, rgb(0.84, 0.87, 0.86)]), startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: s * 0.5, y: 0)))
            boat.stroke(main, with: .color(.black.opacity(0.12)), lineWidth: 0.8)
            if rig == .reefed {
                // The reefed-down sail bundled on the boom.
                boat.fill(
                    Path(
                        roundedRect: CGRect(x: s * 0.03, y: gooseneck.y - s * 0.07, width: s * 0.46, height: s * 0.07),
                        cornerRadius: s * 0.035),
                    with: .color(sailColor.opacity(0.85)))
            }
            // Partly rolled away when reefed; the leech fills out aft with the wind.
            let jibSail = jib(s: s, furl: rig == .reefed ? 0.35 : 0, roach: belly * 0.35 + flutter / s)
            boat.fill(jibSail, with: .color(rgb(0.9, 0.93, 0.92)))
            boat.stroke(jibSail, with: .color(.black.opacity(0.12)), lineWidth: 0.8)

        case .furled:
            // Sails stowed: the main lashed to the boom, the jib taken down.
            boat.fill(
                Path(
                    roundedRect: CGRect(x: s * 0.02, y: gooseneck.y - s * 0.09, width: s * 0.48, height: s * 0.09),
                    cornerRadius: s * 0.045),
                with: .color(sailColor))
        }

        // Forestay, from just under the masthead down to the stemhead.
        boat.stroke(
            Path {
                $0.move(to: forestayTop(s)); $0.addLine(to: stemhead(s))
            },
            with: .color(wood.opacity(0.7)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

        // Boom.
        boat.stroke(
            Path {
                $0.move(to: gooseneck); $0.addLine(to: boomEnd)
            },
            with: .color(wood), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        drawPennant(&boat, masthead: masthead, s: s)

        // Hull: a raked, pointed bow (left) and a near-upright transom stern (right), so
        // the way it's heading reads at a glance.
        var hull = Path()
        hull.move(to: stemhead(s))
        hull.addLine(to: CGPoint(x: s * 0.54, y: -s * 0.1))
        hull.addLine(to: CGPoint(x: s * 0.47, y: s * 0.1))
        hull.addQuadCurve(to: CGPoint(x: s * 0.3, y: s * 0.17), control: CGPoint(x: s * 0.45, y: s * 0.17))
        hull.addLine(to: CGPoint(x: -s * 0.22, y: s * 0.17))
        hull.addQuadCurve(to: stemhead(s), control: CGPoint(x: -s * 0.52, y: s * 0.14))
        hull.closeSubpath()
        boat.fill(
            hull,
            with: .linearGradient(
                Gradient(colors: [Theme.coral, rgb(0.82, 0.4, 0.28)]), startPoint: CGPoint(x: 0, y: -s * 0.1),
                endPoint: CGPoint(x: 0, y: s * 0.17)))
        boat.fill(
            Path(CGRect(x: -s * 0.6, y: -s * 0.12, width: s * 1.14, height: s * 0.035)),
            with: .color(Theme.pearl.opacity(0.9)))
    }

    /// Where the forestay meets the mast, in the boat's frame.
    private func forestayTop(_ s: Double) -> CGPoint { CGPoint(x: 0, y: -s * 0.92) }
    /// The tip of the bow, where the forestay comes down to the deck.
    private func stemhead(_ s: Double) -> CGPoint { CGPoint(x: -s * 0.64, y: -s * 0.1) }

    /// The jib, set on the forestay ahead of the mast: its luff runs straight down the
    /// forestay to the bow, its foot back toward the mast, and its leech curves up to the
    /// head. `furl` (0…1) rolls it away down the forestay; `roach` bows the leech out aft
    /// (positive, full of wind) or sags it in (negative), as a fraction of `s`.
    private func jib(s: Double, furl: Double, roach: Double) -> Path {
        let top = forestayTop(s)
        let tack = CGPoint(x: -s * 0.58, y: -s * 0.13)
        let fullClew = CGPoint(x: -s * 0.07, y: -s * 0.18)
        let head = CGPoint(x: top.x + (tack.x - top.x) * furl, y: top.y + (tack.y - top.y) * furl + s * 0.04)
        let clew = CGPoint(x: tack.x + (fullClew.x - tack.x) * (1 - furl * 0.5), y: fullClew.y)
        var path = Path()
        path.move(to: head)
        path.addLine(to: tack)
        path.addLine(to: clew)
        path.addQuadCurve(
            to: head, control: CGPoint(x: (clew.x + head.x) / 2 + roach * s, y: (clew.y + head.y) / 2))
        path.closeSubpath()
        return path
    }

    /// The masthead pennant: hangs down in a calm, lifts in a breeze, streams straight
    /// and snaps when it blows hard.
    private func drawPennant(_ context: inout GraphicsContext, masthead: CGPoint, s: Double) {
        let strength = min(weather.windSpeed / 10, 1)
        let length = s * 0.2
        // 0 straight down … π/2 straight out downwind. The boat runs before the wind, so
        // downwind is always toward the bow: −x in the boat's frame.
        let lift = (0.15 + strength * 1.42)
        let flapRate = 2 + strength * 7
        let flap = sin(t * flapRate) * (0.08 + (1 - strength) * 0.06)
        let a = lift + flap
        let tip = CGPoint(x: masthead.x - sin(a) * length, y: masthead.y + cos(a) * length)
        let mid = CGPoint(
            x: masthead.x - sin(a + flap) * length * 0.5,
            y: masthead.y + cos(a + flap) * length * 0.5 - s * 0.02)
        var pennant = Path()
        pennant.move(to: masthead)
        pennant.addQuadCurve(to: tip, control: mid)
        let back = CGPoint(
            x: masthead.x - sin(a) * s * 0.02, y: masthead.y + s * 0.07 * (1 - strength * 0.4))
        pennant.addQuadCurve(to: back, control: CGPoint(x: (tip.x + back.x) / 2, y: (tip.y + back.y) / 2 + s * 0.02))
        pennant.closeSubpath()
        context.fill(pennant, with: .color(Theme.coral))
    }

    /// A wake fading out behind the stern, upwind, longer the harder it sails.
    private func drawWake(_ context: inout GraphicsContext, x: Double, y: Double, s: Double) {
        let length = s * (rig == .reefed ? 1.4 : 1) * wind.wakeDirection
        let start = x + s * 0.45 * wind.wakeDirection
        // Starts at the hull's waterline and settles onto the wave surface as it trails, so
        // it stays attached to the stern while the boat rides the damped swell.
        var wake = Path()
        for step in 0...12 {
            let f = Double(step) / 12
            let surface = waveY(start + f * length, layer: 0)
            let blend = min(f * 2.5, 1)
            let point = CGPoint(x: start + f * length, y: y + (surface - y) * blend + 1.5 + f * 2)
            step == 0 ? wake.move(to: point) : wake.addLine(to: point)
        }
        context.stroke(
            wake,
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.6), .white.opacity(0)]), startPoint: CGPoint(x: start, y: y),
                endPoint: CGPoint(x: start + length, y: y)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// The boat mirrored in glassy water.
    private func drawReflection(_ context: inout GraphicsContext, x: Double, y: Double, s: Double) {
        var mirror = context
        mirror.clip(to: Path(CGRect(x: 0, y: y + 1, width: w, height: h - y)))
        mirror.translateBy(x: x, y: y + s * 0.12)
        mirror.scaleBy(x: wind.hullScale, y: -0.55)
        mirror.opacity = 0.22
        drawBoatShape(&mirror, s: s)
    }

    // MARK: Helpers

    private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let u = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// A stable pseudo-random number in 0..<1 for an index and a salt, so every frame
    /// draws the same drops, stars and clouds.
    private func hash(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 73_856_093 ^ salt &* 19_349_663)
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        x = x &* 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }
}

/// How the scene's wind runs across the card, and how the boat sits in it. The card is
/// a side view looking north, so a west wind blows left to right. The boat is drawn in
/// profile, where the wind runs along its length, so it can only be shown running before
/// the wind: its bow points downwind, its wake trails upwind and its pennant streams
/// ahead. Pointing it the other way would put it head to wind, where it
/// can't sail.
struct SceneWind: Equatable {
    /// +1 when the wind blows left to right on screen (from the west), −1 the other way.
    /// Winds from near north or south, with little sideways push, blow left to right.
    let sign: Double

    init(windFrom degrees: Double) {
        sign = sin(degrees * .pi / 180) > 0.2 ? -1 : 1
    }

    /// The bow's direction on screen: +1 right, −1 left. Always downwind.
    var bowDirection: Double { sign }
    /// The wake trails from the stern, upwind.
    var wakeDirection: Double { -sign }
    /// The x scale that turns the boat's own frame (drawn bow to the left) to face downwind.
    var hullScale: Double { -sign }

    /// From the boat's own frame (origin at the waterline amidships, bow to the left, y
    /// down) to the screen: faced downwind, turned by `angle` (clockwise positive), and
    /// placed at `origin`.
    func boatTransform(at origin: CGPoint, angle: Double) -> CGAffineTransform {
        CGAffineTransform(scaleX: hullScale, y: 1)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}

/// How the boat tilts: level on flat water, never heeled by the wind, and only rocked by
/// the waves under it.
enum BoatMotion {
    /// Most a building sea rocks the boat on top of the swell's slope, radians.
    static let maxRock = 0.045

    /// The boat's on-screen angle (radians, clockwise positive). `slope` is the water's
    /// rise from the hull's left end to its right (screen y over x, so positive when the
    /// right end sits lower); `sea` runs 0 (flat) … 1 (a big sea); `t` is in seconds.
    /// With no sea the boat sits dead level, matching its reflection, whatever ripple the
    /// calm water still draws.
    static func angle(slope: Double, sea: Double, t: Double) -> Double {
        let sea = min(max(sea, 0), 1)
        guard sea > 0 else { return 0 }
        let follow = atan(slope) * 0.35
        let rock = sin(t * (0.8 + 0.4 * sea)) * maxRock * sea
        return follow + rock
    }
}
