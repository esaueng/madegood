import AppIntents
import WaterKit

// Shortcuts actions, which also put MadeGood on the Apple Watch Ultra's Action button
// (Settings > Action Button > Shortcut): start a sport, and add a lap while recording.

/// The sports, as Shortcuts shows them.
enum SportOption: String, AppEnum {
    case sailing, windsurfing, motorboating, kayak, canoe, sup

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sport"
    static let caseDisplayRepresentations: [SportOption: DisplayRepresentation] = [
        .sailing: DisplayRepresentation(title: "Sailing", image: .init(systemName: "sailboat")),
        .windsurfing: DisplayRepresentation(title: "Windsurfing", image: .init(systemName: "wind")),
        .motorboating: DisplayRepresentation(title: "Motorboating", image: .init(systemName: "ferry")),
        .kayak: DisplayRepresentation(title: "Kayak", image: .init(systemName: "oar.2.crossed")),
        .canoe: DisplayRepresentation(title: "Canoe", image: .init(systemName: "oar.2.crossed")),
        .sup: DisplayRepresentation(title: "SUP", image: .init(systemName: "figure.stand")),
    ]

    var sport: Sport { Sport(rawValue: rawValue) ?? .sailing }
}

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Session"
    static let description = IntentDescription(
        "Starts recording a session for a sport, through the sport's countdown if it has one.")
    static let openAppWhenRun = true

    @Parameter(title: "Sport")
    var sport: SportOption

    init() {}

    init(sport: SportOption) {
        self.sport = sport
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = SessionController.shared
        guard !controller.isBusy else {
            return .result(dialog: "A session is already running.")
        }
        controller.begin(sport.sport)
        return .result(dialog: "Starting \(sport.sport.displayName).")
    }
}

struct AddLapIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Lap"
    static let description = IntentDescription("Closes the current lap of the session being recorded.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = SessionController.shared
        guard controller.recorder.isRecording else {
            return .result(dialog: "No session is recording.")
        }
        controller.lap()
        let lap = controller.recorder.metrics.map { $0.currentLap.index } ?? 0
        return .result(dialog: "Lap \(lap)")
    }
}

struct MadeGoodShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start a \(\.$sport) session in \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Start Session",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: AddLapIntent(),
            phrases: ["Add a lap in \(.applicationName)"],
            shortTitle: "Add Lap",
            systemImageName: "stopwatch"
        )
    }
}
