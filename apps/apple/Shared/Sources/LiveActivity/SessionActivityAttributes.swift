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
            /// Man-overboard guidance ("120 m · 245°", or "Waiting for GPS") while a mark is
            /// set, else nil. Optional, so states from earlier builds still decode.
            var manOverboard: String? = nil
        }

        var sportName: String
        /// Asset name of the sport's icon (Shared/Resources/SportIcons.xcassets). Activities
        /// started by builds before the drawn icons hold an SF Symbol name here instead.
        var sportIcon: String
        var startedAt: Date

        /// The icon is stored under its old key, so an activity started by an earlier build
        /// still decodes after an update.
        enum CodingKeys: String, CodingKey {
            case sportName
            case sportIcon = "sportSymbol"
            case startedAt
        }

        /// Whether `sportIcon` is an SF Symbol name from an earlier build.
        var isLegacySymbol: Bool { !sportIcon.hasPrefix("sport.") }
    }
#endif
