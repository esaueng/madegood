import Foundation
import WaterKit

/// Display units and text for live metrics. Values stay SI until here (AGENTS.md).
struct LiveDisplay {
    var speed: SpeedUnit
    var distance: DistanceUnit

    /// Defaults until the units setting exists (#21 follow-up): nautical units on boats
    /// and boards, metric for paddling.
    static func standard(for sport: Sport) -> LiveDisplay {
        sport.isPaddling
            ? LiveDisplay(speed: .kilometresPerHour, distance: .metric)
            : LiveDisplay(speed: .knots, distance: .nauticalMiles)
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

    static func course(_ degrees: Double?) -> String {
        guard let degrees else { return "–" }
        return "\(Int(degrees.rounded()) % 360)°"
    }

    static func pauseLabel(_ state: LiveMetrics.PauseState) -> String? {
        switch state {
        case .moving: nil
        case .autoPaused: "Auto-paused"
        case .manuallyPaused: "Paused"
        }
    }
}
