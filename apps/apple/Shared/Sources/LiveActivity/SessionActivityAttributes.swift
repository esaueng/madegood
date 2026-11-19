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
            /// Man-overboard guidance ("120 m · 245°", "Waiting for GPS", or a location
            /// problem) while a mark is set or a press waits, else nil. The fields below are
            /// optional too, so states from earlier builds still decode.
            var manOverboard: String? = nil
            /// Whether `manOverboard` is distance and bearing from a fresh position (it
            /// expires with the content's stale date) rather than a waiting message.
            var manOverboardHasGuidance: Bool? = nil
            /// Whether `manOverboard` says location is denied, restricted or approximate.
            var manOverboardLocationIssue: Bool? = nil
            /// How far to trust the mark ("Marked from a position 32 s old"), if not fully.
            var manOverboardNote: String? = nil
            /// When the fix behind the guidance was measured; the stale date follows it.
            var manOverboardFixAt: Date? = nil

            /// No mark, waiting for a position, guidance, or a location problem: a change
            /// between these goes out at once.
            var manOverboardKind: Int {
                guard manOverboard != nil else { return 0 }
                if manOverboardLocationIssue == true { return 3 }
                return manOverboardHasGuidance == true ? 2 : 1
            }
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
