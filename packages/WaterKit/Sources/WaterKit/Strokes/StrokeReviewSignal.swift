import Foundation

/// The wrist motion of a recording as a person reviews strokes in it: 25 Hz bins, each
/// channel band-passed 0.3–3 Hz, and their projection on the main axis of movement. It
/// follows the steps of `StrokeDetector` (docs/metrics.md "Strokes") with its own simple
/// implementation, so a review page stays readable when the detector changes: the detector's
/// cycles sit on the positive peaks of `main`, and for kayak the other blade's stroke sits
/// near the trough between them.
///
/// The filters are causal like the detector's, so peaks lag the motion by the same amount
/// and the candidates line up with them.
public struct StrokeReviewSignal: Sendable {
    /// Bin width, s.
    public static let interval = 0.04
    /// Time of bin 0's centre, s since the session start.
    public var start: Double
    /// Main-axis projection per bin; NaN where the recording has no motion.
    public var main: [Double]
    /// Band-passed rotation rate x, y, z per bin, rad/s; NaN where there is no motion.
    public var rotation: [[Double]]

    public var count: Int { main.count }

    /// `cycleTimes` (session time) choose the sign of each stretch so that cycles sit on
    /// positive peaks; leave it empty to keep the axis's own sign.
    public init(motion: [MotionSample], cycleTimes: [Double] = []) {
        let interval = Self.interval
        guard let first = motion.first, let last = motion.last, last.t >= first.t else {
            start = 0
            main = []
            rotation = [[], [], []]
            return
        }
        let binCount = Int(((last.t - first.t) / interval).rounded(.down)) + 1
        start = first.t + interval / 2

        // Mean of the six channels per bin (acceleration in rad/s-equivalent units).
        var sums = [[Double]](repeating: [Double](repeating: 0, count: 6), count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for sample in motion {
            let index = min(binCount - 1, max(0, Int((sample.t - first.t) / interval)))
            let r = sample.rotationRate
            let a = sample.userAcceleration
            let values = [r.x, r.y, r.z, a.x / 4, a.y / 4, a.z / 4]
            for channel in 0..<6 { sums[index][channel] += values[channel] }
            counts[index] += 1
        }

        // Fill short gaps (≤ 0.2 s) by interpolation; a longer gap restarts the filters.
        var bins = [[Double]?](repeating: nil, count: binCount)
        for index in 0..<binCount where counts[index] > 0 {
            bins[index] = sums[index].map { $0 / Double(counts[index]) }
        }
        var restarts = Set<Int>()
        var previous: Int?
        for index in 0..<binCount where bins[index] != nil {
            if let p = previous, index - p > 1 {
                if Double(index - p) * interval <= 0.2, let a = bins[p], let b = bins[index] {
                    for k in (p + 1)..<index {
                        let f = Double(k - p) / Double(index - p)
                        bins[k] = zip(a, b).map { $0 + ($1 - $0) * f }
                    }
                } else {
                    restarts.insert(index)
                }
            }
            previous = index
        }

        // Band-pass each channel.
        let rate = 1 / interval
        var filtered = [[Double]?](repeating: nil, count: binCount)
        var filters = Self.makeFilters(rate: rate)
        for index in 0..<binCount {
            guard let bin = bins[index] else { continue }
            if restarts.contains(index) { filters = Self.makeFilters(rate: rate) }
            var output = [Double](repeating: 0, count: 6)
            for channel in 0..<6 {
                let high = filters[channel].0.step(bin[channel])
                output[channel] = filters[channel].1.step(high)
            }
            filtered[index] = output
        }

        // Main axis over the last 3 s, refreshed every 0.5 s; sign kept from the last axis.
        let window = Int((3.0 / interval).rounded())
        let refresh = Int((0.5 / interval).rounded())
        var axes = [[Double]?](repeating: nil, count: binCount)
        var axis: [Double]?
        var segmentStart = 0
        for index in 0..<binCount {
            if filtered[index] == nil {
                axis = nil
                segmentStart = index + 1
            } else if restarts.contains(index) {
                axis = nil
                segmentStart = index
            }
            if index - segmentStart + 1 >= window / 2, (index - segmentStart) % refresh == 0 {
                let rows = filtered[max(segmentStart, index - window + 1)...index].compactMap { $0 }
                if let found = Self.principalAxis(rows, previous: axis) { axis = found }
            }
            axes[index] = axis
        }
        // The first bins of a stretch use its first axis.
        var nextAxis: [Double]?
        for index in stride(from: binCount - 1, through: 0, by: -1) {
            if filtered[index] == nil || restarts.contains(index + 1) { nextAxis = nil }
            if let found = axes[index] { nextAxis = found } else { axes[index] = nextAxis }
        }

        var main = [Double](repeating: .nan, count: binCount)
        var rotation = [[Double]](repeating: [Double](repeating: .nan, count: binCount), count: 3)
        for index in 0..<binCount {
            guard let values = filtered[index] else { continue }
            for channel in 0..<3 { rotation[channel][index] = values[channel] }
            if let axis = axes[index] {
                main[index] = zip(values, axis).reduce(0) { $0 + $1.0 * $1.1 }
            }
        }

        // Point each stretch's peaks at the detector's cycles.
        if !cycleTimes.isEmpty {
            var stretchStart = 0
            for index in 0...binCount where index == binCount || main[index].isNaN || restarts.contains(index) {
                if index > stretchStart {
                    let lower = start + Double(stretchStart) * interval
                    let upper = start + Double(index - 1) * interval
                    var sum = 0.0
                    for t in cycleTimes where t >= lower && t <= upper {
                        let bin = Int(((t - start) / interval).rounded())
                        if bin >= stretchStart && bin < index { sum += main[bin] }
                    }
                    if sum < 0 {
                        for k in stretchStart..<index { main[k] = -main[k] }
                    }
                }
                stretchStart = index + 1
                if index < binCount, !main[index].isNaN { stretchStart = index }
            }
        }
        self.main = main
        self.rotation = rotation
    }

    /// Time of bin `index`'s centre, s.
    public func time(ofBin index: Int) -> Double { start + Double(index) * Self.interval }

    // MARK: Filters

    /// Second-order Butterworth sections (high-pass 0.3 Hz, low-pass 3 Hz) per channel.
    static func makeFilters(rate: Double) -> [(Section, Section)] {
        (0..<6).map { _ in (Section(highPass: 0.3, rate: rate), Section(lowPass: 3, rate: rate)) }
    }

    struct Section: Sendable {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(lowPass cutoff: Double, rate: Double) {
            let w = 2 * Double.pi * cutoff / rate
            let alpha = sin(w) / (2 * 0.5.squareRoot())
            let c = cos(w)
            let a0 = 1 + alpha
            b0 = (1 - c) / 2 / a0
            b1 = (1 - c) / a0
            b2 = (1 - c) / 2 / a0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        init(highPass cutoff: Double, rate: Double) {
            let w = 2 * Double.pi * cutoff / rate
            let alpha = sin(w) / (2 * 0.5.squareRoot())
            let c = cos(w)
            let a0 = 1 + alpha
            b0 = (1 + c) / 2 / a0
            b1 = -(1 + c) / a0
            b2 = (1 + c) / 2 / a0
            a1 = -2 * c / a0
            a2 = (1 - alpha) / a0
        }

        mutating func step(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    /// The unit eigenvector of the rows' covariance with the largest eigenvalue, by power
    /// iteration, pointing the same way as `previous`. Nil without movement.
    static func principalAxis(_ rows: [[Double]], previous: [Double]?) -> [Double]? {
        guard rows.count >= 2 else { return nil }
        let n = 6
        var covariance = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for row in rows {
            for i in 0..<n {
                for j in i..<n { covariance[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<n {
            for j in 0..<i { covariance[i][j] = covariance[j][i] }
        }
        // Start away from any single eigenvector so the dominant one is always found.
        var vector = [Double](repeating: 0.3, count: n)
        if let previous { vector = zip(vector, previous).map { $0 + $1 } }
        for _ in 0..<60 {
            var next = [Double](repeating: 0, count: n)
            for i in 0..<n {
                for j in 0..<n { next[i] += covariance[i][j] * vector[j] }
            }
            let norm = next.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-12, norm.isFinite else { return nil }
            vector = next.map { $0 / norm }
        }
        if let previous, zip(vector, previous).reduce(0, { $0 + $1.0 * $1.1 }) < 0 {
            vector = vector.map { -$0 }
        }
        return vector
    }
}
