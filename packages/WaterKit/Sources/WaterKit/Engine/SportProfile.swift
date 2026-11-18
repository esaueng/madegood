/// Per-sport defaults for the live session engine. The app can override any field
/// from the user's settings; these are the starting values.
public struct SportProfile: Sendable, Hashable {
    public var sport: Sport
    public var autoPause: AutoPause.Config
    /// Close a lap automatically every this many metres; nil for manual laps only.
    public var autoLapDistance: Double?
    /// Whether the session is saved to Apple Health as a workout by default.
    public var savesWorkoutByDefault: Bool
    /// Whether the engine tracks the speedsurfing categories (docs/metrics.md).
    public var tracksSpeedCategories: Bool

    public init(
        sport: Sport, autoPause: AutoPause.Config, autoLapDistance: Double? = nil, savesWorkoutByDefault: Bool = true,
        tracksSpeedCategories: Bool? = nil
    ) {
        self.sport = sport
        self.autoPause = autoPause
        self.autoLapDistance = autoLapDistance
        self.savesWorkoutByDefault = savesWorkoutByDefault
        self.tracksSpeedCategories = tracksSpeedCategories ?? (sport == .windsurfing)
    }

    /// Defaults from docs/PLAN.md §5: auto-pause is on for paddling and off for sailing,
    /// windsurfing and motorboating, where drifting or waiting for wind is part of the
    /// session. Motorboat trips are not Health workouts unless the user opts in.
    public static func standard(for sport: Sport) -> SportProfile {
        switch sport {
        case .kayak, .canoe, .sup:
            SportProfile(sport: sport, autoPause: AutoPause.Config(enabled: true))
        case .sailing, .windsurfing:
            SportProfile(sport: sport, autoPause: AutoPause.Config(enabled: false))
        case .motorboating:
            SportProfile(sport: sport, autoPause: AutoPause.Config(enabled: false), savesWorkoutByDefault: false)
        }
    }
}
