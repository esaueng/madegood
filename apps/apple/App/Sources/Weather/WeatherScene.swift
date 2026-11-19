import SwiftUI
import WaterKit

/// A little animated seascape for the conditions: the sky, sun or moon, clouds, rain,
/// snow, fog and lightning; waves, whitecaps and wind streaks that grow with the wind;
/// and a small sailboat whose rig shows the wind: slack sails in a calm, full and heeled
/// in a breeze, reefed when it's strong, furled when it's too much. Still with Reduce
/// Motion. Decorative: the card around it carries the words.
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
    /// +1 when the wind blows left to right on screen (from the west), −1 the other way.
    private var windSign: Double { sin(weather.windFrom * .pi / 180) > 0.2 ? -1 : 1 }
    private var stormy: Bool { sky == .thunderstorm }
    private var wet: Bool { [.rain, .drizzle, .thunderstorm, .snow].contains(sky) }

    func draw(in context: inout GraphicsContext) {
        drawSky(&context)
        if mood == .stormComing { drawStormBank(&context) }
        if night { drawStars(&context) }
        if showsSun { night ? drawMoon(&context) : drawSun(&context) }
        drawClouds(&context)
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
        [.clear, .partlyCloudy].contains(sky)
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
        // A warm glow low on a sunny horizon.
        if !night, showsSun {
            context.fill(
                Path(CGRect(x: 0, y: horizon - h * 0.25, width: w, height: h * 0.25)),
                with: .linearGradient(
                    Gradient(colors: [.clear, rgb(1, 0.86, 0.6).opacity(0.25)]),
                    startPoint: CGPoint(x: 0, y: horizon - h * 0.25), endPoint: CGPoint(x: 0, y: horizon)))
        }
    }

    /// A wall of dark cloud building on the horizon, upwind.
    private func drawStormBank(_ context: inout GraphicsContext) {
        let fromRight = windSign < 0
        let edge = fromRight ? w : 0
        let start = CGPoint(x: fromRight ? w * 0.35 : w * 0.65, y: 0)
        context.fill(
            Path(CGRect(origin: .zero, size: CGSize(width: w, height: horizon))),
            with: .linearGradient(
                Gradient(colors: [.clear, rgb(0.12, 0.1, 0.22).opacity(0.75)]),
                startPoint: start, endPoint: CGPoint(x: edge, y: 0)))
        let creep = sin(t * 0.4) * 4
        for i in 0..<5 {
            let x = fromRight ? w - Double(i) * w * 0.09 + creep : Double(i) * w * 0.09 - creep
            let r = h * (0.16 - Double(i) * 0.018)
            cloud(&context, center: CGPoint(x: x, y: horizon - r * 0.7), scale: r / 20, color: rgb(0.2, 0.18, 0.3))
        }
    }

    private func drawStars(_ context: inout GraphicsContext) {
        for i in 0..<22 {
            let x = hash(i, 1) * w
            let y = hash(i, 2) * horizon * 0.8
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (1.2 + hash(i, 3) * 2) + Double(i)))
            let r = 0.7 + hash(i, 4) * 1.1
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(twinkle * (wet ? 0.3 : 0.9))))
        }
    }

    private var sunCenter: CGPoint { CGPoint(x: w * 0.93, y: h * 0.22) }

    /// A smiling sun that turns its rays slowly and blinks now and then.
    private func drawSun(_ context: inout GraphicsContext) {
        let c = sunCenter
        let r = h * 0.12
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r * 2.6, y: c.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
            with: .radialGradient(
                Gradient(colors: [rgb(1, 0.92, 0.55).opacity(0.55), .clear]), center: c, startRadius: r * 0.8,
                endRadius: r * 2.6))
        var rays = Path()
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi + t * 0.25
            let pulse = 1 + 0.08 * sin(t * 2 + Double(i))
            rays.move(to: CGPoint(x: c.x + cos(a) * r * 1.3, y: c.y + sin(a) * r * 1.3))
            rays.addLine(to: CGPoint(x: c.x + cos(a) * r * 1.75 * pulse, y: c.y + sin(a) * r * 1.75 * pulse))
        }
        context.stroke(rays, with: .color(rgb(1, 0.85, 0.35)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        context.fill(
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
            with: .linearGradient(
                Gradient(colors: [rgb(1, 0.92, 0.45), rgb(1, 0.74, 0.25)]), startPoint: CGPoint(x: c.x, y: c.y - r),
                endPoint: CGPoint(x: c.x, y: c.y + r)))
        face(
            &context, center: CGPoint(x: c.x, y: c.y + r * 0.08), size: r, expression: .happy, ink: rgb(0.55, 0.3, 0.05)
        )
        // Rosy cheeks.
        for side in [-1.0, 1.0] {
            let cheek = CGRect(x: c.x + side * r * 0.52 - r * 0.15, y: c.y + r * 0.22, width: r * 0.3, height: r * 0.18)
            context.fill(Path(ellipseIn: cheek), with: .color(rgb(1, 0.5, 0.4).opacity(0.45)))
        }
    }

    /// A crescent moon with a sleepy face.
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
        // A closed eye and a small smile on the crescent's inner side.
        var eye = Path()
        eye.addArc(
            center: CGPoint(x: c.x - r * 0.55, y: c.y - r * 0.1), radius: r * 0.13, startAngle: .degrees(20),
            endAngle: .degrees(160), clockwise: false)
        context.stroke(eye, with: .color(rgb(0.4, 0.38, 0.3)), lineWidth: 1.3)
    }

    // MARK: Clouds

    private var cloudCount: Int {
        switch sky {
        case .clear: return night ? 0 : 1
        case .partlyCloudy: return 3
        case .overcast, .rain, .thunderstorm: return 5
        case .drizzle, .snow: return 4
        case .fog: return 2
        }
    }

    private var cloudColor: Color {
        switch sky {
        case .clear, .partlyCloudy: return night ? rgb(0.55, 0.6, 0.72) : .white
        case .overcast: return rgb(0.85, 0.88, 0.92)
        case .drizzle, .fog: return rgb(0.78, 0.81, 0.85)
        case .snow: return rgb(0.93, 0.95, 0.97)
        case .rain: return rgb(0.55, 0.6, 0.68)
        case .thunderstorm: return rgb(0.3, 0.28, 0.4)
        }
    }

    private var cloudExpression: Expression? {
        switch sky {
        case .rain: .sad
        case .thunderstorm: .grumpy
        case .drizzle: .sleepy
        case .snow: .content
        case .clear, .partlyCloudy, .overcast, .fog: nil
        }
    }

    private func drawClouds(_ context: inout GraphicsContext) {
        let speed = 5 + weather.windSpeed * 2.4
        let span = w + 140
        for i in 0..<cloudCount {
            let scale = 0.8 + hash(i, 7) * 0.7 + (wet ? 0.35 : 0)
            let base = hash(i, 8) * span + Double(i) * span / Double(max(cloudCount, 1))
            var x = (base + t * speed * windSign * (0.7 + hash(i, 9) * 0.6)).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            x -= 70
            let y = h * (0.12 + hash(i, 10) * 0.28) + (wet ? -h * 0.04 : 0)
            let center = CGPoint(x: x, y: y)
            // Clouds fade as they drift behind the words on the left.
            var layer = context
            layer.opacity = 0.15 + 0.85 * smoothstep(w * 0.3, w * 0.62, x)
            // Darker underside first, for a little depth.
            cloud(&layer, center: CGPoint(x: x + 1.5, y: y + 2.5), scale: scale, color: .black.opacity(0.08))
            cloud(&layer, center: center, scale: scale, color: cloudColor)
            if i == 0, let expression = cloudExpression {
                face(
                    &layer, center: CGPoint(x: x, y: y + 2 * scale), size: 9 * scale, expression: expression,
                    ink: sky == .thunderstorm ? rgb(0.95, 0.9, 1) : rgb(0.25, 0.3, 0.4))
            }
        }
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
        let count = sky == .drizzle ? 26 : sky == .thunderstorm ? 70 : 50
        let length = sky == .drizzle ? 5.0 : 11
        let slant = windSign * min(windiness, 1) * 0.45
        let fall = horizon + 10
        var drops = Path()
        for i in 0..<count {
            let speed = (sky == .drizzle ? 120 : 260) + hash(i, 11) * 80
            let y = (hash(i, 12) * fall + t * speed).truncatingRemainder(dividingBy: fall)
            var x = (hash(i, 13) * (w + 40) + slant * y).truncatingRemainder(dividingBy: w + 40)
            if x < 0 { x += w + 40 }
            x -= 20
            drops.move(to: CGPoint(x: x, y: y))
            drops.addLine(to: CGPoint(x: x - slant * length, y: y - length))
        }
        context.stroke(
            drops, with: .color(.white.opacity(sky == .drizzle ? 0.45 : 0.55)),
            style: StrokeStyle(lineWidth: sky == .drizzle ? 1 : 1.4, lineCap: .round))
        // Little rings where drops land.
        for i in 0..<8 {
            let phase = (t * 1.4 + hash(i, 14)).truncatingRemainder(dividingBy: 1)
            let x = hash(i, 15) * w
            let y = horizon + 8 + hash(i, 16) * (h - horizon - 12)
            let rx = 2 + phase * 7
            context.stroke(
                Path(ellipseIn: CGRect(x: x - rx, y: y - rx * 0.3, width: rx * 2, height: rx * 0.6)),
                with: .color(.white.opacity((1 - phase) * 0.4)), lineWidth: 0.8)
        }
    }

    private func drawSnow(_ context: inout GraphicsContext) {
        for i in 0..<42 {
            let fall = h + 10
            let speed = 14 + hash(i, 17) * 22
            let y = (hash(i, 18) * fall + t * speed).truncatingRemainder(dividingBy: fall) - 5
            var x = hash(i, 19) * w + sin(t * 1.3 + Double(i)) * 7 + t * windSign * weather.windSpeed * 1.5
            x = x.truncatingRemainder(dividingBy: w)
            if x < 0 { x += w }
            let r = 1.2 + hash(i, 20) * 1.8
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.9)))
        }
    }

    private func drawFog(_ context: inout GraphicsContext) {
        var context = context
        context.addFilter(.blur(radius: h * 0.04))
        for i in 0..<5 {
            let y = h * (0.3 + Double(i) * 0.14)
            let drift = sin(t * 0.15 + Double(i) * 1.7) * w * 0.12
            let band = CGRect(x: -w * 0.3 + drift, y: y, width: w * 1.6, height: h * 0.11)
            context.fill(
                Path(roundedRect: band, cornerRadius: h * 0.055),
                with: .color(rgb(0.9, 0.92, 0.94).opacity(0.42 + 0.08 * sin(t * 0.5 + Double(i)))))
        }
    }

    /// A bright flash and a bolt every few seconds; far off and faint when only coming.
    private func drawLightning(_ context: inout GraphicsContext) {
        let distant = !stormy
        let period = distant ? 5.3 : 3.7
        let cycle = floor(t / period)
        let phase = t - cycle * period
        let flashing = phase < 0.1 || (phase > 0.18 && phase < 0.26)
        guard flashing else { return }
        if !distant {
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.28)))
        }
        let seed = Int(cycle) & 0xFFFF
        let x0: Double
        if distant {
            x0 = windSign < 0 ? w * (0.8 + hash(seed, 21) * 0.15) : w * (0.05 + hash(seed, 21) * 0.15)
        } else {
            x0 = w * (0.15 + hash(seed, 21) * 0.5)
        }
        let top = distant ? horizon - h * 0.2 : h * 0.22
        let bottom = horizon
        var bolt = Path()
        bolt.move(to: CGPoint(x: x0, y: top))
        var x = x0
        let steps = 5
        for step in 1...steps {
            x += (hash(seed + step, 22) - 0.5) * (distant ? 8 : 18)
            bolt.addLine(to: CGPoint(x: x, y: top + (bottom - top) * Double(step) / Double(steps)))
        }
        context.stroke(
            bolt, with: .color(rgb(1, 0.95, 0.6).opacity(distant ? 0.7 : 1)),
            style: StrokeStyle(lineWidth: distant ? 1.4 : 2.6, lineCap: .round, lineJoin: .round))
    }

    /// Cartoon gust lines, more and faster as the wind rises, each ending in a curl.
    private func drawWindStreaks(_ context: inout GraphicsContext) {
        let count = Int(2 + windiness * 6)
        let speed = 90 + windiness * 140
        for i in 0..<count {
            let length = 36 + hash(i, 23) * 40
            let travel = w + length * 2
            let progress = ((t * speed / travel) + hash(i, 24)).truncatingRemainder(dividingBy: 1)
            let head = windSign > 0 ? -length + progress * travel : w + length - progress * travel
            let y = h * (0.15 + hash(i, 25) * 0.4)
            let alpha = sin(progress * .pi) * 0.55
            var path = Path()
            let tail = head - windSign * length
            path.move(to: CGPoint(x: tail, y: y))
            path.addQuadCurve(
                to: CGPoint(x: head, y: y), control: CGPoint(x: (tail + head) / 2, y: y - 4 * sin(Double(i))))
            // The curl.
            let curl = 5.0
            path.addArc(
                center: CGPoint(x: head, y: y - curl), radius: curl, startAngle: .degrees(90),
                endAngle: .degrees(windSign > 0 ? -60 : 240), clockwise: windSign < 0)
            context.stroke(
                path, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
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
        for layer in [0.0, 1.0, 2.0] {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            var x = 0.0
            while x <= w + 4 {
                path.addLine(to: CGPoint(x: x, y: waveY(x, layer: layer)))
                x += 4
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            let shade = layer / 2
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

    /// Sun glitter on calm water, under the sun.
    private func drawGlitter(_ context: inout GraphicsContext) {
        for i in 0..<9 {
            let y = horizon + 6 + Double(i) * (h - horizon - 8) / 9
            let spread = 6 + Double(i) * 3.2
            let x = sunCenter.x + (hash(i, 26) - 0.5) * spread * 2
            let width = (5 + hash(i, 27) * 9) * (0.6 + 0.4 * sin(t * 3 + Double(i)))
            let rect = CGRect(x: x - width / 2, y: y, width: width, height: 1.5)
            context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(rgb(1, 0.95, 0.75).opacity(0.65)))
        }
    }

    private func drawWhitecaps(_ context: inout GraphicsContext) {
        let count = outlook.wind >= .strong ? 12 : 7
        let speed = 30 + windiness * 30
        for i in 0..<count {
            let layer = Double(i % 3)
            let life = 2.2
            let phase = (t / life + hash(i, 28)).truncatingRemainder(dividingBy: 1)
            var x = (hash(i, 29) * w + t * speed * windSign).truncatingRemainder(dividingBy: w)
            if x < 0 { x += w }
            let y = waveY(x, layer: layer)
            let widthNow = (7 + hash(i, 30) * 8) * sin(phase * .pi)
            var cap = Path()
            cap.move(to: CGPoint(x: x - widthNow / 2, y: y + 1))
            cap.addQuadCurve(to: CGPoint(x: x + widthNow / 2, y: y + 1), control: CGPoint(x: x, y: y - 3))
            context.stroke(
                cap, with: .color(.white.opacity(0.85 * sin(phase * .pi))),
                style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    // MARK: Boat

    private var boatExpression: Expression {
        switch mood {
        case .thunderstorm, .stormComing, .tooWindy: .worried
        case .glassy, .clearNight: .sleepy
        case .sailingBreeze: .delighted
        case .sunny, .partlyCloudy: .happy
        case .rain, .drizzle, .fog, .cloudy, .snow: .meh
        }
    }

    /// How the boat is rigged for the conditions, so the wind reads at a glance.
    private enum Rig {
        /// No wind: sails hang slack, the pennant droops, a reflection on flat water.
        case slack
        /// Sails drawing, a little heel.
        case drawing
        /// Sails full and taut, well heeled, a bow wave and a wake.
        case powered
        /// Main reefed down, heeled hard, spray off the bow.
        case reefed
        /// Too windy or thunder: sails furled, rocking at anchor.
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

    /// Heel in radians, positive to leeward (the way the wind blows).
    private var heel: Double {
        switch rig {
        case .slack: 0
        case .drawing: 0.1
        case .powered: outlook.wind == .fresh ? 0.36 : 0.26
        case .reefed: 0.4
        case .furled: 0.05
        }
    }

    private func drawBoat(_ context: inout GraphicsContext) {
        let s = h * 0.42
        let x = w * 0.78
        let waterline = waveY(x, layer: 0)
        let slope = (waveY(x + 6, layer: 0) - waveY(x - 6, layer: 0)) / 12
        let rock: Double
        switch rig {
        case .furled: rock = sin(t * 2.6) * 0.2 + sin(t * 4.1) * 0.06
        case .reefed: rock = sin(t * 2.2) * 0.07
        case .slack: rock = sin(t * 0.8) * 0.015
        case .drawing, .powered: rock = sin(t * 1.4) * 0.035
        }
        let bob = sin(t * (rig == .slack ? 0.9 : 1.6)) * (rig == .slack ? 0.6 : 1.2)
        let y = waterline + s * 0.06 + bob
        let angle = atan(slope) * 0.8 + windSign * heel + rock

        if rig == .powered || rig == .reefed { drawWake(&context, x: x, y: waterline, s: s) }
        if rig == .slack { drawReflection(&context, x: x, y: waterline, s: s) }

        var boat = context
        boat.translateBy(x: x, y: y)
        boat.rotate(by: .radians(angle))
        if sky == .fog { boat.opacity = 0.7 }
        drawBoatShape(&boat, s: s)

        face(
            &boat, center: CGPoint(x: -s * 0.05, y: s * 0.03), size: s * 0.16, expression: boatExpression,
            ink: rgb(0.25, 0.1, 0.08))
        if boatExpression == .sleepy { drawZs(&boat, origin: CGPoint(x: s * 0.2, y: -s * 0.3)) }
        if rig == .reefed || rig == .furled || outlook.wind >= .fresh { drawSpray(&boat, s: s) }
    }

    /// Mast, boom, sails for the rig, pennant and hull, in the boat's own frame (origin at
    /// the waterline amidships, bow to the left).
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
        // Forestay to the bow.
        boat.stroke(
            Path {
                $0.move(to: CGPoint(x: 0, y: -s * 0.95)); $0.addLine(to: CGPoint(x: -s * 0.5, y: -s * 0.1))
            },
            with: .color(wood.opacity(0.6)), lineWidth: 0.7)

        switch rig {
        case .slack:
            // Hanging limp: the leech sags in, with a few creases, stirring a little.
            let stir = sin(t * 1.8) * s * 0.015
            var main = Path()
            main.move(to: CGPoint(x: s * 0.03, y: -s * 0.98))
            main.addQuadCurve(to: CGPoint(x: s * 0.42 + stir, y: -s * 0.18), control: CGPoint(x: s * 0.1, y: -s * 0.5))
            main.addLine(to: CGPoint(x: s * 0.03, y: -s * 0.18))
            main.closeSubpath()
            boat.fill(main, with: .color(sailColor.opacity(0.92)))
            var creases = Path()
            for i in 0..<3 {
                let yy = -s * (0.36 + Double(i) * 0.16)
                creases.move(to: CGPoint(x: s * 0.06, y: yy))
                creases.addQuadCurve(
                    to: CGPoint(x: s * (0.2 - Double(i) * 0.04), y: yy + s * 0.08),
                    control: CGPoint(x: s * 0.16, y: yy + s * 0.01))
            }
            boat.stroke(creases, with: .color(.black.opacity(0.16)), lineWidth: 0.8)
            var jib = Path()
            jib.move(to: CGPoint(x: -s * 0.03, y: -s * 0.9))
            jib.addQuadCurve(
                to: CGPoint(x: -s * 0.34 - stir, y: -s * 0.14), control: CGPoint(x: -s * 0.08, y: -s * 0.4))
            jib.addLine(to: CGPoint(x: -s * 0.03, y: -s * 0.14))
            jib.closeSubpath()
            boat.fill(jib, with: .color(rgb(0.9, 0.93, 0.92).opacity(0.92)))

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
            // Batten lines show the sail is pulling.
            var battens = Path()
            for i in 1...2 {
                let f = Double(i) / 3
                let yy = head + (gooseneck.y - head) * f
                battens.move(to: CGPoint(x: s * 0.05, y: yy))
                battens.addLine(to: CGPoint(x: s * (0.05 + 0.3 * f + belly * 0.4), y: yy + s * 0.02))
            }
            boat.stroke(battens, with: .color(.black.opacity(0.1)), lineWidth: 0.8)
            if rig == .reefed {
                // The reefed-down sail bundled on the boom.
                boat.fill(
                    Path(
                        roundedRect: CGRect(x: s * 0.03, y: gooseneck.y - s * 0.07, width: s * 0.46, height: s * 0.07),
                        cornerRadius: s * 0.035),
                    with: .color(sailColor.opacity(0.85)))
            }
            var jib = Path()
            let jibHead = rig == .reefed ? -s * 0.6 : -s * 0.92
            jib.move(to: CGPoint(x: -s * 0.03, y: jibHead))
            jib.addQuadCurve(
                to: CGPoint(x: -s * 0.4, y: -s * 0.14),
                control: CGPoint(x: -s * (0.12 + belly), y: jibHead * 0.45))
            jib.addLine(to: CGPoint(x: -s * 0.03, y: -s * 0.14))
            jib.closeSubpath()
            boat.fill(jib, with: .color(rgb(0.9, 0.93, 0.92)))

        case .furled:
            // Sails stowed: the main lashed to the boom, the jib rolled on the forestay.
            boat.fill(
                Path(
                    roundedRect: CGRect(x: s * 0.02, y: gooseneck.y - s * 0.09, width: s * 0.48, height: s * 0.09),
                    cornerRadius: s * 0.045),
                with: .color(sailColor))
            var ties = Path()
            for i in 1...3 {
                let xx = s * (0.02 + 0.12 * Double(i))
                ties.move(to: CGPoint(x: xx, y: gooseneck.y - s * 0.09))
                ties.addLine(to: CGPoint(x: xx, y: gooseneck.y))
            }
            boat.stroke(ties, with: .color(Theme.coral), lineWidth: 1.2)
            boat.stroke(
                Path {
                    $0.move(to: CGPoint(x: -s * 0.04, y: -s * 0.86));
                    $0.addLine(to: CGPoint(x: -s * 0.44, y: -s * 0.16))
                },
                with: .color(sailColor), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // Boom.
        boat.stroke(
            Path {
                $0.move(to: gooseneck); $0.addLine(to: boomEnd)
            },
            with: .color(wood), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        drawPennant(&boat, masthead: masthead, s: s)

        // Hull.
        var hull = Path()
        hull.move(to: CGPoint(x: -s * 0.56, y: -s * 0.1))
        hull.addLine(to: CGPoint(x: s * 0.58, y: -s * 0.1))
        hull.addQuadCurve(to: CGPoint(x: s * 0.36, y: s * 0.17), control: CGPoint(x: s * 0.52, y: s * 0.12))
        hull.addLine(to: CGPoint(x: -s * 0.34, y: s * 0.17))
        hull.addQuadCurve(to: CGPoint(x: -s * 0.56, y: -s * 0.1), control: CGPoint(x: -s * 0.52, y: s * 0.12))
        hull.closeSubpath()
        boat.fill(
            hull,
            with: .linearGradient(
                Gradient(colors: [Theme.coral, rgb(0.82, 0.4, 0.28)]), startPoint: CGPoint(x: 0, y: -s * 0.1),
                endPoint: CGPoint(x: 0, y: s * 0.17)))
        boat.fill(
            Path(CGRect(x: -s * 0.56, y: -s * 0.12, width: s * 1.14, height: s * 0.035)),
            with: .color(Theme.pearl.opacity(0.9)))
    }

    /// The masthead pennant: hangs down in a calm, lifts in a breeze, streams straight
    /// and snaps when it blows hard.
    private func drawPennant(_ context: inout GraphicsContext, masthead: CGPoint, s: Double) {
        let strength = min(weather.windSpeed / 10, 1)
        let length = s * 0.2
        // 0 straight down … π/2 straight out downwind.
        let lift = (0.15 + strength * 1.42)
        let flapRate = 2 + strength * 16
        let flap = sin(t * flapRate) * (0.12 + (1 - strength) * 0.1)
        let a = lift + flap
        let tip = CGPoint(x: masthead.x + windSign * sin(a) * length, y: masthead.y + cos(a) * length)
        let mid = CGPoint(
            x: masthead.x + windSign * sin(a + flap) * length * 0.5,
            y: masthead.y + cos(a + flap) * length * 0.5 - s * 0.02)
        var pennant = Path()
        pennant.move(to: masthead)
        pennant.addQuadCurve(to: tip, control: mid)
        let back = CGPoint(
            x: masthead.x + windSign * sin(a) * s * 0.02, y: masthead.y + s * 0.07 * (1 - strength * 0.4))
        pennant.addQuadCurve(to: back, control: CGPoint(x: (tip.x + back.x) / 2, y: (tip.y + back.y) / 2 + s * 0.02))
        pennant.closeSubpath()
        context.fill(pennant, with: .color(Theme.coral))
    }

    /// Foam trailing from the stern and a bow wave, longer the harder it sails.
    private func drawWake(_ context: inout GraphicsContext, x: Double, y: Double, s: Double) {
        let length = s * (rig == .reefed ? 1.6 : 1.1)
        for line in 0..<3 {
            let offset = Double(line) * 3
            let dash = (t * 40).truncatingRemainder(dividingBy: 12)
            var wake = Path()
            wake.move(to: CGPoint(x: x + s * 0.5, y: y + 1 + offset))
            wake.addQuadCurve(
                to: CGPoint(x: x + s * 0.5 + length, y: y + 3 + offset * 1.6),
                control: CGPoint(x: x + s * 0.5 + length * 0.5, y: y + offset))
            context.stroke(
                wake, with: .color(.white.opacity(0.45 - Double(line) * 0.12)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [6, 6], dashPhase: -dash))
        }
        var bow = Path()
        bow.move(to: CGPoint(x: x - s * 0.62, y: y + 2))
        bow.addQuadCurve(to: CGPoint(x: x - s * 0.42, y: y - 2), control: CGPoint(x: x - s * 0.58, y: y - 5))
        context.stroke(bow, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// The boat mirrored in glassy water.
    private func drawReflection(_ context: inout GraphicsContext, x: Double, y: Double, s: Double) {
        var mirror = context
        mirror.clip(to: Path(CGRect(x: 0, y: y + 1, width: w, height: h - y)))
        mirror.translateBy(x: x, y: y + s * 0.12)
        mirror.scaleBy(x: 1, y: -0.55)
        mirror.opacity = 0.22
        drawBoatShape(&mirror, s: s)
    }

    /// Spray flying off the windward bow.
    private func drawSpray(_ boat: inout GraphicsContext, s: Double) {
        let count = rig == .furled ? 8 : 5
        for i in 0..<count {
            let phase = (t * 1.8 + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let px = -windSign * s * 0.55 - windSign * phase * s * 0.25 * (hash(i, 31) + 0.5)
            let py = -s * 0.05 - sin(phase * .pi) * s * 0.28
            let r = 1.1 + hash(i, 32) * 1.1
            boat.fill(
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.85 * (1 - phase))))
        }
    }

    /// Little z's drifting up from a dozing boat.
    private func drawZs(_ context: inout GraphicsContext, origin: CGPoint) {
        for i in 0..<3 {
            let phase = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let text = Text("z").font(.system(size: 7 + phase * 6, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(sin(phase * .pi) * 0.9))
            context.draw(
                text, at: CGPoint(x: origin.x + phase * 14 + sin(phase * 6) * 3, y: origin.y - phase * 26))
        }
    }

    // MARK: Faces

    enum Expression { case happy, delighted, worried, sleepy, meh, sad, grumpy, content }

    /// Two eyes and a mouth, `size` across, with a blink every few seconds.
    private func face(
        _ context: inout GraphicsContext, center c: CGPoint, size s: Double, expression: Expression, ink: Color
    ) {
        let eyeGap = s * 0.42
        let eyeY = c.y - s * 0.12
        let blink = (t + c.x * 0.01).truncatingRemainder(dividingBy: 4.3) < 0.13
        let closed = expression == .sleepy || expression == .content || blink
        for side in [-1.0, 1.0] {
            let ex = c.x + side * eyeGap / 2
            if closed {
                var lid = Path()
                if expression == .content {
                    // Happy upturned arcs: ^ ^
                    lid.addArc(
                        center: CGPoint(x: ex, y: eyeY + s * 0.06), radius: s * 0.09, startAngle: .degrees(200),
                        endAngle: .degrees(340), clockwise: false)
                } else {
                    lid.addArc(
                        center: CGPoint(x: ex, y: eyeY - s * 0.04), radius: s * 0.09, startAngle: .degrees(20),
                        endAngle: .degrees(160), clockwise: false)
                }
                context.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: max(1, s * 0.07), lineCap: .round))
            } else {
                let r = expression == .worried ? s * 0.11 : s * 0.085
                context.fill(
                    Path(ellipseIn: CGRect(x: ex - r, y: eyeY - r * 1.15, width: r * 2, height: r * 2.3)),
                    with: .color(ink))
                if expression == .worried || expression == .delighted {
                    let glint = r * 0.4
                    context.fill(
                        Path(ellipseIn: CGRect(x: ex - r * 0.2, y: eyeY - r * 0.8, width: glint, height: glint)),
                        with: .color(.white))
                }
            }
            if expression == .grumpy {
                var brow = Path()
                brow.move(to: CGPoint(x: ex - side * s * 0.14, y: eyeY - s * 0.26))
                brow.addLine(to: CGPoint(x: ex + side * s * 0.08, y: eyeY - s * 0.15))
                context.stroke(
                    brow, with: .color(ink), style: StrokeStyle(lineWidth: max(1, s * 0.07), lineCap: .round))
            }
        }
        let mouthY = c.y + s * 0.14
        var mouth = Path()
        let lineWidth = max(1, s * 0.07)
        switch expression {
        case .happy, .content:
            mouth.addArc(
                center: CGPoint(x: c.x, y: mouthY - s * 0.06), radius: s * 0.14, startAngle: .degrees(25),
                endAngle: .degrees(155), clockwise: false)
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        case .delighted:
            mouth.move(to: CGPoint(x: c.x - s * 0.16, y: mouthY - s * 0.02))
            mouth.addQuadCurve(
                to: CGPoint(x: c.x + s * 0.16, y: mouthY - s * 0.02), control: CGPoint(x: c.x, y: mouthY + s * 0.26))
            mouth.closeSubpath()
            context.fill(mouth, with: .color(ink))
        case .worried:
            context.stroke(
                Path(ellipseIn: CGRect(x: c.x - s * 0.06, y: mouthY - s * 0.02, width: s * 0.12, height: s * 0.15)),
                with: .color(ink), lineWidth: lineWidth)
        case .sleepy:
            mouth.addArc(
                center: CGPoint(x: c.x, y: mouthY - s * 0.02), radius: s * 0.07, startAngle: .degrees(30),
                endAngle: .degrees(150), clockwise: false)
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        case .meh:
            mouth.move(to: CGPoint(x: c.x - s * 0.1, y: mouthY + s * 0.03))
            mouth.addLine(to: CGPoint(x: c.x + s * 0.1, y: mouthY + s * 0.03))
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        case .sad, .grumpy:
            mouth.addArc(
                center: CGPoint(x: c.x, y: mouthY + s * 0.12), radius: s * 0.12, startAngle: .degrees(215),
                endAngle: .degrees(325), clockwise: false)
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
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
