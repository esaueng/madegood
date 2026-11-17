#if os(iOS)
    import ActivityKit
    import Foundation

    /// The Lock Screen and Dynamic Island Live Activity for a session on the iPhone
    /// (docs/PLAN.md §6). Values are already formatted for display, so the widget
    /// extension needs no units logic.
    struct SessionActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            var speed: String
            /// The speed without its unit, for the narrow compact Dynamic Island.
            var speedNumber: String
            var distance: String
            var movingTime: String
            /// "Paused" or "Auto-paused", or nil while moving.
            var pauseLabel: String?
        }

        var sportName: String
        var sportSymbol: String
        var startedAt: Date
    }
#endif
