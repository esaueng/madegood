import Foundation

/// Paddle stroke detection from wrist motion (docs/PLAN.md §5, docs/metrics.md "Strokes").
///
/// Causal and streaming, so the same code runs live on the watch and phone and over a
/// whole recording afterwards. The pipeline:
///
/// 1. Motion samples are averaged into fixed 40 ms bins (25 Hz), whatever the sensor rate.
/// 2. Each of the six channels (rotation rate, and user acceleration scaled to a comparable
///    size) is band-passed to 0.3–3 Hz.
/// 3. The filtered vector is projected onto its main axis of movement: the first principal
///    component over the last 3 s, refreshed every 0.5 s and kept pointing the same way.
/// 4. A wrist cycle is a positive lobe of that signal above an adaptive threshold (a share
///    of its running RMS, never below a noise floor), followed by a swing below a negative
///    hysteresis level. Cycles closer than the minimum gap are merged.
///
/// Kayak counts two strokes per wrist cycle (left and right); canoe and SUP count one, and
/// track the paddling side from the change in wrist orientation (gravity in the device frame).
public struct StrokeDetector: LiveAnalyzer {
    public struct Config: Sendable, Hashable {
        /// Width of the averaging bins, s (25 Hz).
        public var binInterval = 0.04
        /// Pass band of the stroke signal, Hz.
        public var lowCut = 0.3
        public var highCut = 3.0
        /// Window of the principal-axis estimate, s, and how often it is refreshed. PLAN §5
        /// suggests 5 s; 3 s follows a canoe or SUP side switch within about a stroke,
        /// where 5 s missed a stroke or two at each switch on the synthetic tests.
        public var axisWindow = 3.0
        public var axisUpdateInterval = 0.5
        /// User acceleration is divided by this before it is combined with rotation rate,
        /// m/s² per rad/s, so neither dominates just because of its unit.
        public var accelerationScale = 4.0
        /// Time constant of the running RMS behind the adaptive threshold, s.
        public var rmsTimeConstant = 3.0
        /// A cycle's peak must exceed this share of the running RMS...
        public var thresholdFactor = 0.5
        /// ...and this absolute floor, which keeps sensor noise at rest from counting.
        public var thresholdFloor = 0.25
        /// After a peak the signal must fall below -hysteresisFactor × threshold before
        /// the next cycle can start.
        public var hysteresisFactor = 0.3
        /// Peaks closer than max(minCycleGap, minGapFraction × typical period) are one cycle, s.
        public var minCycleGap = 0.33
        public var minGapFraction = 0.45
        /// A longer interval between cycles is a pause: it does not count toward the rate, s.
        public var maxCyclePeriod = 4.0
        /// The rate uses the median of up to this many recent cycle periods.
        public var rateCycles = 6
        /// A sensor gap longer than this restarts the filters, s.
        public var restartAfterGap = 1.0
        /// Side switches (canoe, SUP): a cycle whose mean gravity direction is further than
        /// this from the current side's is a candidate, degrees...
        public var sideSwitchAngle = 40.0
        /// ...and this many candidates in a row, within `sideAgreementAngle` of their
        /// mean, confirm a switch.
        public var sideSwitchCycles = 3
        public var sideAgreementAngle = 30.0

        public init() {}
    }

    /// One detected wrist cycle. Kayak cycles hold two strokes, canoe and SUP cycles one.
    public struct Cycle: Sendable, Hashable {
        /// Time of the cycle's peak, s (same clock as the samples).
        public var t: Double
        /// Time since the previous cycle when it counts toward the rate (not across a
        /// pause or sensor gap), s.
        public var period: Double?
        /// Paddling side, 0 or 1, for single-blade sports; nil for kayak. Side 0 is the side
        /// paddled first, not left or right: the watch cannot tell which wrist it is on.
        public var side: Int?
    }

    public struct Metrics: Sendable, Hashable {
        public var strokeCount: Int
        /// Strokes per minute from the recent cycles; nil before three cycles in a row or
        /// once paddling has stopped.
        public var strokeRate: Double?
        /// Confirmed side switches (canoe, SUP).
        public var sideSwitches: Int
        public var lastStrokeAt: Double?

        public init(strokeCount: Int = 0, strokeRate: Double? = nil, sideSwitches: Int = 0, lastStrokeAt: Double? = nil) {
            self.strokeCount = strokeCount
            self.strokeRate = strokeRate
            self.sideSwitches = sideSwitches
            self.lastStrokeAt = lastStrokeAt
        }
    }

    public let config: Config
    public let strokesPerCycle: Int
    public let tracksSide: Bool
    /// Every detected cycle, when created with `recordsCycles` (post-session analysis).
    public private(set) var cycles: [Cycle] = []
    private let recordsCycles: Bool

    // Binning
    private var binIndex: Int?
    private var binSum = [Double](repeating: 0, count: 9)
    private var binCount = 0
    private var lastBin: [Double]?
    // Filtering
    private var highPass: [Biquad] = []
    private var lowPass: [Biquad] = []
    private var filtersPrimed = false
    // Principal axis
    private var window: [[Double]] = []
    /// Time of the first bin in `window` while it has not wrapped yet.
    private var windowStart = 0.0
    private var windowHead = 0
    private var binsSinceAxis = 0
    private var axis: [Double]?
    // Detection
    private var meanSquare = 0.0
    private var inLobe = false
    private var lobePeak = (t: 0.0, value: 0.0)
    /// The previous two projected values, for locating a peak between bins.
    private var previous: (older: Double, old: Double)?
    private var peakIsPrevious = false
    private var gravitySum = Vector3.zero
    private var gravityCount = 0
    private var cycleGravity = Vector3.zero
    private var lastPeak: Double?
    private var periods: [Double] = []
    private var latestTime: Double?
    private var strokeCount = 0
    // Sides
    private var side = 0
    private var sideReference: Vector3?
    private var sideCandidates: [(gravity: Vector3, cycle: Int?)] = []
    private var sideSwitches = 0

    public init(sport: Sport, config: Config = Config(), recordsCycles: Bool = false) {
        self.config = config
        strokesPerCycle = sport == .kayak ? 2 : 1
        tracksSide = sport == .canoe || sport == .sup
        self.recordsCycles = recordsCycles
        resetFilters()
    }

    public mutating func ingest(_ sample: Sample) {
        if case .motion(let motion) = sample { ingest(motion) }
    }

    public mutating func ingest(_ sample: MotionSample) {
        let values = [
            sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z,
            sample.userAcceleration.x / config.accelerationScale,
            sample.userAcceleration.y / config.accelerationScale,
            sample.userAcceleration.z / config.accelerationScale,
            sample.gravity.x, sample.gravity.y, sample.gravity.z,
        ]
        guard sample.t.isFinite, values.allSatisfy(\.isFinite) else { return }
        let index = Int((sample.t / config.binInterval).rounded(.down))
        latestTime = max(latestTime ?? sample.t, sample.t)
        if let current = binIndex {
            if index < current { return }
            if index > current {
                closeBin(current)
                let missing = index - current - 1
                if Double(missing) * config.binInterval > config.restartAfterGap {
                    restart(at: Double(index) * config.binInterval)
                } else if let held = lastBin {
                    for gap in 0..<missing { process(held, at: Double(current + 1 + gap) * config.binInterval) }
                }
                binIndex = index
            }
        } else {
            binIndex = index
        }
        for channel in values.indices { binSum[channel] += values[channel] }
        binCount += 1
    }

    /// Moves the clock forward without a sample, so the rate blanks when the sensor is quiet.
    public mutating func advance(to t: Double) {
        guard t.isFinite else { return }
        latestTime = max(latestTime ?? t, t)
    }

    public var snapshot: Metrics {
        Metrics(strokeCount: strokeCount, strokeRate: strokeRate, sideSwitches: sideSwitches, lastStrokeAt: lastPeak)
    }

    private var strokeRate: Double? {
        guard periods.count >= 2, let lastPeak, let latestTime else { return nil }
        let period = Self.median(periods)
        guard latestTime - lastPeak <= min(config.maxCyclePeriod, 2.5 * period) + period else { return nil }
        return Self.rate(periods: periods, strokesPerCycle: strokesPerCycle)
    }

    /// Strokes per minute from recent cycle periods: the mean period, leaving out periods
    /// far from the median (a missed or split cycle). The mean of consecutive periods
    /// cancels most of the timing error of the individual peaks.
    static func rate(periods: [Double], strokesPerCycle: Int) -> Double? {
        guard !periods.isEmpty else { return nil }
        let median = median(periods)
        let typical = periods.filter { $0 >= 0.6 * median && $0 <= 1.6 * median }
        let mean = typical.reduce(0, +) / Double(typical.count)
        return mean > 0 ? 60 * Double(strokesPerCycle) / mean : nil
    }

    // MARK: - Pipeline

    private mutating func closeBin(_ index: Int) {
        guard binCount > 0 else { return }
        let mean = binSum.map { $0 / Double(binCount) }
        binSum = [Double](repeating: 0, count: binSum.count)
        binCount = 0
        lastBin = mean
        process(mean, at: (Double(index) + 0.5) * config.binInterval)
    }

    private mutating func restart(at t: Double) {
        resetFilters()
        window.removeAll(keepingCapacity: true)
        windowHead = 0
        binsSinceAxis = 0
        inLobe = false
        previous = nil
        meanSquare = 0
        lastBin = nil
        // A gap is a pause: the next cycle's period does not count.
        lastPeak = nil
        periods.removeAll()
        gravitySum = .zero
        gravityCount = 0
    }

    private mutating func resetFilters() {
        let rate = 1 / config.binInterval
        highPass = (0..<6).map { _ in Biquad.highPass(cutoff: config.lowCut, sampleRate: rate) }
        lowPass = (0..<6).map { _ in Biquad.lowPass(cutoff: config.highCut, sampleRate: rate) }
        filtersPrimed = false
    }

    private mutating func process(_ bin: [Double], at t: Double) {
        if !filtersPrimed {
            for channel in 0..<6 {
                highPass[channel].prime(bin[channel])
                lowPass[channel].prime(0)
            }
            filtersPrimed = true
        }
        var filtered = [Double](repeating: 0, count: 6)
        for channel in 0..<6 {
            filtered[channel] = lowPass[channel].step(highPass[channel].step(bin[channel]))
        }
        gravitySum.x += bin[6]
        gravitySum.y += bin[7]
        gravitySum.z += bin[8]
        gravityCount += 1

        let capacity = Int((config.axisWindow / config.binInterval).rounded())
        if window.isEmpty { windowStart = t }
        if window.count < capacity {
            window.append(filtered)
        } else {
            window[windowHead] = filtered
            windowHead = (windowHead + 1) % capacity
        }
        binsSinceAxis += 1
        let minimumBins = Int((1 / config.binInterval).rounded())
        let hadAxis = axis != nil
        if window.count >= minimumBins,
            !hadAxis || Double(binsSinceAxis) * config.binInterval >= config.axisUpdateInterval
        {
            updateAxis()
            binsSinceAxis = 0
        }
        guard let axis else { return }
        if hadAxis {
            project(filtered, on: axis, at: t)
        } else {
            // The first axis: run detection over the bins that were waiting for it (the
            // window has not wrapped yet, so they are in time order), so the first stroke
            // after a start or a gap still counts.
            for (offset, row) in window.enumerated() {
                project(row, on: axis, at: windowStart + Double(offset) * config.binInterval)
            }
        }
    }

    private mutating func project(_ filtered: [Double], on axis: [Double], at t: Double) {
        var x = 0.0
        for channel in 0..<6 { x += axis[channel] * filtered[channel] }
        meanSquare += (config.binInterval / config.rmsTimeConstant) * (x * x - meanSquare)
        detect(x, at: t)
    }

    private mutating func detect(_ x: Double, at t: Double) {
        defer { previous = (previous?.old ?? x, x) }
        let threshold = max(config.thresholdFloor, config.thresholdFactor * meanSquare.squareRoot())
        if inLobe {
            if x > lobePeak.value {
                lobePeak = (t, x)
                peakIsPrevious = true
            } else if peakIsPrevious, let previous {
                peakIsPrevious = false
                // The bin before was the top: fit a parabola through it and its neighbours.
                let curvature = previous.older - 2 * previous.old + x
                if curvature < 0 {
                    let offset = 0.5 * (previous.older - x) / curvature
                    lobePeak.t += max(-0.5, min(0.5, offset)) * config.binInterval
                }
            }
            if x < -config.hysteresisFactor * threshold {
                inLobe = false
                cycleEnded(peak: lobePeak.t)
            }
        } else if x > threshold {
            inLobe = true
            lobePeak = (t, x)
            peakIsPrevious = true
        }
    }

    private mutating func cycleEnded(peak: Double) {
        let typical = periods.isEmpty ? nil : Self.median(periods)
        let minimumGap = max(config.minCycleGap, config.minGapFraction * (typical ?? 0))
        if let lastPeak, peak - lastPeak < minimumGap {
            // Part of the previous cycle: a harmonic, or a wobble at the catch.
            return
        }
        var period: Double?
        if let lastPeak {
            let interval = peak - lastPeak
            if interval <= config.maxCyclePeriod {
                period = interval
                periods.append(interval)
                if periods.count > config.rateCycles { periods.removeFirst(periods.count - config.rateCycles) }
            } else {
                periods.removeAll()
            }
        }
        lastPeak = peak
        strokeCount += strokesPerCycle
        if gravityCount > 0 {
            cycleGravity = Vector3(
                x: gravitySum.x / Double(gravityCount), y: gravitySum.y / Double(gravityCount),
                z: gravitySum.z / Double(gravityCount))
        }
        gravitySum = .zero
        gravityCount = 0
        if recordsCycles { cycles.append(Cycle(t: peak, period: period, side: tracksSide ? side : nil)) }
        if tracksSide { updateSide(Self.normalized(cycleGravity), cycle: recordsCycles ? cycles.count - 1 : nil) }
    }

    private mutating func updateSide(_ gravity: Vector3?, cycle: Int?) {
        guard let gravity else { return }
        guard let reference = sideReference else {
            sideReference = gravity
            return
        }
        if Self.angle(gravity, reference) <= config.sideSwitchAngle {
            sideCandidates.removeAll()
            sideReference = Self.normalized(
                Vector3(
                    x: reference.x * 0.8 + gravity.x * 0.2, y: reference.y * 0.8 + gravity.y * 0.2,
                    z: reference.z * 0.8 + gravity.z * 0.2)) ?? reference
            return
        }
        sideCandidates.append((gravity, cycle))
        guard sideCandidates.count >= config.sideSwitchCycles else { return }
        let sum = sideCandidates.reduce(Vector3.zero) {
            Vector3(x: $0.x + $1.gravity.x, y: $0.y + $1.gravity.y, z: $0.z + $1.gravity.z)
        }
        guard let mean = Self.normalized(sum),
            sideCandidates.allSatisfy({ Self.angle($0.gravity, mean) <= config.sideAgreementAngle })
        else {
            sideCandidates.removeFirst()
            return
        }
        side = 1 - side
        sideSwitches += 1
        sideReference = mean
        for candidate in sideCandidates {
            if let index = candidate.cycle { cycles[index].side = side }
        }
        sideCandidates.removeAll()
    }

    private mutating func updateAxis() {
        let count = Double(window.count)
        var mean = [Double](repeating: 0, count: 6)
        for row in window { for channel in 0..<6 { mean[channel] += row[channel] / count } }
        var covariance = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for row in window {
            for i in 0..<6 {
                let di = row[i] - mean[i]
                for j in i..<6 { covariance[i][j] += di * (row[j] - mean[j]) }
            }
        }
        var trace = 0.0
        for i in 0..<6 {
            for j in i..<6 {
                covariance[i][j] /= count
                covariance[j][i] = covariance[i][j]
            }
            trace += covariance[i][i]
        }
        // Too little movement to define an axis: keep the last one.
        guard trace > 1e-9 else { return }
        // Power iteration, starting from the previous axis so it changes smoothly.
        var vector = axis ?? (0..<6).map { covariance[$0][$0] + 1e-6 }
        for _ in 0..<30 {
            var next = [Double](repeating: 0, count: 6)
            for i in 0..<6 { for j in 0..<6 { next[i] += covariance[i][j] * vector[j] } }
            let norm = next.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0, norm.isFinite else { return }
            vector = next.map { $0 / norm }
        }
        if let axis, zip(axis, vector).reduce(0, { $0 + $1.0 * $1.1 }) < 0 {
            vector = vector.map { -$0 }
        }
        axis = vector
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func normalized(_ v: Vector3) -> Vector3? {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        guard length > 1e-9, length.isFinite else { return nil }
        return Vector3(x: v.x / length, y: v.y / length, z: v.z / length)
    }

    /// Angle between two unit vectors, degrees.
    static func angle(_ a: Vector3, _ b: Vector3) -> Double {
        let dot = min(1, max(-1, a.x * b.x + a.y * b.y + a.z * b.z))
        return acos(dot) * 180 / .pi
    }
}

/// A second-order IIR section (RBJ cookbook, Butterworth Q), direct form II transposed.
struct Biquad: Sendable, Hashable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0
    /// Gain at 0 Hz, used to start the filter in its steady state.
    var dcGain: Double { (b0 + b1 + b2) / (1 + a1 + a2) }

    static func lowPass(cutoff: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = parameters(cutoff: cutoff, sampleRate: sampleRate)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cosine) / 2 / a0, b1: (1 - cosine) / a0, b2: (1 - cosine) / 2 / a0,
            a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
    }

    static func highPass(cutoff: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = parameters(cutoff: cutoff, sampleRate: sampleRate)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cosine) / 2 / a0, b1: -(1 + cosine) / a0, b2: (1 + cosine) / 2 / a0,
            a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
    }

    private static func parameters(cutoff: Double, sampleRate: Double) -> (cosine: Double, alpha: Double) {
        let omega = 2 * Double.pi * cutoff / sampleRate
        return (cos(omega), sin(omega) / (2 * 0.5.squareRoot()))
    }

    /// Sets the state as if `x` had been the input forever.
    mutating func prime(_ x: Double) {
        let y = dcGain * x
        z2 = b2 * x - a2 * y
        z1 = b1 * x - a1 * y + z2
    }

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
