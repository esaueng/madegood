#if os(watchOS)
    import AppIntents
    import WatchKit
    import WaterKit

    // The Apple Watch Ultra's Action button (Settings > Action Button > Workout > MadeGood).
    // The first press runs `StartSportWorkoutIntent` for the sport chosen there; every
    // press after that runs `SessionActionButtonIntent`, which syncs or skips a countdown
    // and then does the sport's chosen action (lap, mark or man-overboard). Pressing the
    // Action and side buttons together pauses or resumes. Apple asks for these intents
    // in the watch app itself, not an extension.

    struct StartSportWorkoutIntent: StartWorkoutIntent {
        static let title: LocalizedStringResource = "Start Session"
        static let description = IntentDescription("Starts recording a session for a sport.")

        /// Each sport is offered under First Press in the Action button settings.
        static var suggestedWorkouts: [StartSportWorkoutIntent] {
            SportOption.allCases.map { StartSportWorkoutIntent(style: $0) }
        }

        @Parameter(title: "Sport")
        var workoutStyle: SportOption

        init() {
            workoutStyle = .sailing
        }

        init(style: SportOption) {
            workoutStyle = style
        }

        var displayRepresentation: DisplayRepresentation {
            SportOption.caseDisplayRepresentations[workoutStyle] ?? DisplayRepresentation(title: "Session")
        }

        @MainActor
        func perform() async throws -> some IntentResult {
            // Busy (a countdown or a recording already running): leave it alone, but keep
            // the next press working on it.
            SessionController.shared.begin(workoutStyle.sport)
            return .result(actionButtonIntent: SessionActionButtonIntent())
        }
    }

    /// Every Action button press after the first, while the session runs.
    struct SessionActionButtonIntent: AppIntent {
        static let title: LocalizedStringResource = "Session Action"
        static let description = IntentDescription(
            "Syncs or skips the countdown, then adds a lap, a mark or a man-overboard mark, as set for the sport.")
        static let isDiscoverable = false

        @MainActor
        func perform() async throws -> some IntentResult {
            SessionController.shared.actionButtonPressed()
            return .result(actionButtonIntent: SessionActionButtonIntent())
        }
    }

    /// Action and side buttons pressed together while recording.
    struct PauseSessionIntent: PauseWorkoutIntent {
        static let title: LocalizedStringResource = "Pause Session"

        @MainActor
        func perform() async throws -> some IntentResult {
            let recorder = SessionController.shared.recorder
            if recorder.isRecording, !recorder.isPaused {
                recorder.pause()
                WKInterfaceDevice.current().play(.stop)
            }
            return .result()
        }
    }

    /// Action and side buttons pressed together while paused.
    struct ResumeSessionIntent: ResumeWorkoutIntent {
        static let title: LocalizedStringResource = "Resume Session"

        @MainActor
        func perform() async throws -> some IntentResult {
            let recorder = SessionController.shared.recorder
            if recorder.isRecording, recorder.isPaused {
                recorder.resume()
                WKInterfaceDevice.current().play(.start)
            }
            return .result()
        }
    }
#endif
