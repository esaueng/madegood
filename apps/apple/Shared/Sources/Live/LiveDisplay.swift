import Foundation
import WaterKit

/// Display units and text for live metrics. Values stay SI until here (AGENTS.md).
struct LiveDisplay {
    var speed: SpeedUnit
    var distance: DistanceUnit

    /// The automatic units: nautical on boats and boards, metric for paddling.
    static func standard(for sport: Sport) -> LiveDisplay {
        LiveDisplay(speed: .automatic(for: sport), distance: .automatic(for: sport))
    }

    func speed(_ metresPerSecond: Double?) -> String {
        guard let metresPerSecond else { return "–" }
        return speed.display(metresPerSecond).text
    }

    func distance(_ metres: Double) -> String {
        distance.display(metres).text
    }

    static func heartRate(_ bpm: Double?) -> String {
        guard let bpm else { return "–" }
        return "\(Int(bpm.rounded())) bpm"
    }

    /// Strokes per minute, whole numbers: "62 spm".
    static func strokeRate(_ strokesPerMinute: Double?) -> String {
        guard let strokesPerMinute else { return "–" }
        return "\(Int(strokesPerMinute.rounded())) spm"
    }

    static func strokeCount(_ count: Int?) -> String {
        guard let count else { return "–" }
        return "\(count)"
    }

    static func planing(_ planing: WindsurfAnalysis.Planing?) -> String {
        guard let planing else { return "–" }
        let percent = planing.fraction.formatted(.percent.precision(.fractionLength(0)))
        return "\(Formatting.elapsed(planing.time)) (\(percent))"
    }

    /// Distance over strokes, in metres (feet with statute miles); blank before a stroke.
    func distancePerStroke(distance metres: Double, strokes: Int?) -> String {
        guard let strokes, strokes > 0, metres > 0 else { return "–" }
        return distance.shortLength(metres / Double(strokes)).text
    }

    static func course(_ degrees: Double?) -> String {
        guard let degrees else { return "–" }
        return "\(Int(degrees.rounded()) % 360)°"
    }

    /// "Lap 2" once the user has closed a lap; nil while still on the first.
    static func lapLabel(_ metrics: LiveMetrics?) -> String? {
        guard let metrics, !metrics.laps.isEmpty else { return nil }
        return "Lap \(metrics.currentLap.index)"
    }

    static func pauseLabel(_ state: LiveMetrics.PauseState) -> String? {
        switch state {
        case .moving: nil
        case .autoPaused: "Auto-paused"
        case .manuallyPaused: "Paused"
        }
    }
}
