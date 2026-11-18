import Foundation

/// Synthetic wrist motion for paddling, with a known stroke count and rate. Used by the
/// stroke tests and by the apps' `-demoSession` feed. Deterministic for a given seed.
///
/// Each wrist cycle is a rotation-rate swing with a second harmonic, a phase-shifted
/// acceleration swing on other axes, and a small wrist tilt in the gravity vector. The
/// paddling side sets the watch's orientation (side 1 is rotated by about 110°, as when
/// the hands swap on the shaft). Gaussian noise, per-cycle amplitude and period jitter,
/// and timestamp jitter are added on top.
public struct PaddleMotionSimulator: Sendable {
    public struct Segment: Sendable, Hashable {
        /// Approximate length, s. Paddling segments are rounded to whole wrist cycles.
        public var duration: Double
        /// Strokes per minute; 0 for a pause (noise only).
        public var strokeRate: Double
        /// Paddling side, 0 or 1 (single-blade sports).
        public var side: Int

        public init(duration: Double, strokeRate: Double, side: Int = 0) {
            self.duration = duration
            self.strokeRate = strokeRate
            self.side = side
        }
    }

    public var sport: Sport
    public var segments: [Segment]
    /// Sensor rate, Hz.
    public var sampleRate = 100.0
    /// Peak rotation rate along the main axis, rad/s, and acceleration, m/s².
    public var rotationAmplitude = 2.0
    public var accelerationAmplitude = 5.0
    /// Second harmonic relative to the fundamental.
    public var harmonic = 0.35
    /// Standard deviation of the added noise, rad/s and m/s².
    public var rotationNoise = 0.15
    public var accelerationNoise = 0.5
    /// Per-cycle relative jitter of amplitude and of period.
    public var amplitudeJitter = 0.15
    public var periodJitter = 0.04
    /// Session time of the first sample, s.
    public var startTime = 0.0
    public var seed: UInt64 = 1

    public init(sport: Sport, segments: [Segment]) {
        self.sport = sport
        self.segments = segments
    }

    public struct Output: Sendable {
        public var samples: [MotionSample]
        /// True strokes (two per cycle for kayak).
        public var strokeCount: Int
        /// Peak time of every true cycle.
        public var cycleTimes: [Double]
        /// Side switches between paddling segments.
        public var sideSwitches: Int
        /// The mean stroke rate over paddling segments (strokes over their duration), SPM.
        public var averageStrokeRate: Double
    }

    public func generate() -> Output {
        var random = SplitMix64(seed: seed)
        let strokesPerCycle = sport == .kayak ? 2 : 1
        let dt = 1 / sampleRate
        var samples: [MotionSample] = []
        var cycleTimes: [Double] = []
        var t = startTime
        var paddlingTime = 0.0
        var lastSide: Int?
        var switches = 0

        for segment in segments {
            let side = segment.side == 0 ? 0 : 1
            let pose = Self.pose(side: side)
            if segment.strokeRate <= 0 {
                let end = t + segment.duration
                while t < end {
                    samples.append(sample(t: t, phase: nil, amplitude: 0, pose: pose, random: &random))
                    t += dt
                }
                continue
            }
            if let lastSide, lastSide != side { switches += 1 }
            lastSide = side
            let basePeriod = 60 * Double(strokesPerCycle) / segment.strokeRate
            let cycles = max(1, Int((segment.duration / basePeriod).rounded()))
            for _ in 0..<cycles {
                let period = basePeriod * (1 + periodJitter * random.uniform(-1, 1))
                let amplitude = 1 + amplitudeJitter * random.uniform(-1, 1)
                let cycleStart = t
                // The fundamental peaks at a quarter cycle.
                cycleTimes.append(cycleStart + period / 4)
                while t < cycleStart + period {
                    let phase = (t - cycleStart) / period
                    samples.append(sample(t: t, phase: phase, amplitude: amplitude, pose: pose, random: &random))
                    t += dt
                }
                paddlingTime += period
            }
        }
        let strokes = cycleTimes.count * strokesPerCycle
        return Output(
            samples: samples, strokeCount: strokes, cycleTimes: cycleTimes, sideSwitches: switches,
            averageStrokeRate: paddlingTime > 0 ? 60 * Double(strokes) / paddlingTime : 0)
    }

    private func sample(
        t: Double, phase: Double?, amplitude: Double, pose: [[Double]], random: inout SplitMix64
    ) -> MotionSample {
        let angle = 2 * Double.pi * (phase ?? 0)
        let active = phase == nil ? 0 : amplitude
        let r = rotationAmplitude * active
        let a = accelerationAmplitude * active
        // Paddle frame: rotation mostly about e1, acceleration mostly along e2.
        let rotation = [
            r * (sin(angle) + harmonic * sin(2 * angle + 0.8)),
            0.3 * r * cos(angle),
            0.15 * r * sin(angle + 2.1),
        ]
        let acceleration = [
            0.2 * a * sin(angle + 2.5),
            a * (sin(angle + 0.6) + harmonic * 0.7 * sin(2 * angle)),
            0.4 * a * sin(angle + 1.9),
        ]
        let tilt = 0.25 * active * sin(angle)
        let gravity = [sin(tilt) * RawFormat.standardGravity, 0, -cos(tilt) * RawFormat.standardGravity]
        let device = { (v: [Double]) in Self.apply(pose, v) }
        let rot = device(rotation)
        let acc = device(acceleration)
        let g = device(gravity)
        let timeJitter = random.gaussian() * 0.0005
        return MotionSample(
            t: t + timeJitter,
            userAcceleration: Vector3(
                x: acc[0] + random.gaussian() * accelerationNoise, y: acc[1] + random.gaussian() * accelerationNoise,
                z: acc[2] + random.gaussian() * accelerationNoise),
            gravity: Vector3(x: g[0], y: g[1], z: g[2]),
            rotationRate: Vector3(
                x: rot[0] + random.gaussian() * rotationNoise, y: rot[1] + random.gaussian() * rotationNoise,
                z: rot[2] + random.gaussian() * rotationNoise),
            attitude: .identity)
    }

    /// Device orientation for a side: a fixed tilt, plus about 110° more for side 1.
    static func pose(side: Int) -> [[Double]] {
        let base = multiply(rotationZ(0.5), rotationX(0.4))
        return side == 0 ? base : multiply(rotationY(1.9), base)
    }

    static func rotationX(_ a: Double) -> [[Double]] { [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]] }
    static func rotationY(_ a: Double) -> [[Double]] { [[cos(a), 0, sin(a)], [0, 1, 0], [-sin(a), 0, cos(a)]] }
    static func rotationZ(_ a: Double) -> [[Double]] { [[cos(a), -sin(a), 0], [sin(a), cos(a), 0], [0, 0, 1]] }

    static func multiply(_ m: [[Double]], _ n: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + m[i][$1] * n[$1][j] } } }
    }

    static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { i in m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] }
    }
}

/// A small deterministic generator (SplitMix64), the same on every platform.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = max(unit(), 1e-12)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * unit())
    }
}
