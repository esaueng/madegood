import Foundation
import WaterKit

/// The user's preferences, in UserDefaults on each device. Each value has an "automatic"
/// default that depends on the sport, so most people never need to touch them.
enum UserSettings {
    enum Key {
        static let speedUnit = "settings.speedUnit"
        static let distanceUnit = "settings.distanceUnit"
        static func autoPause(_ sport: Sport) -> String { "settings.autoPause.\(sport.rawValue)" }
        static func saveWorkout(_ sport: Sport) -> String { "settings.saveWorkout.\(sport.rawValue)" }
    }

    /// Stored value for "use the sport's default".
    static let automatic = "auto"

    static var defaults: UserDefaults { .standard }

    static func display(for sport: Sport) -> LiveDisplay {
        var display = LiveDisplay.standard(for: sport)
        if let raw = defaults.string(forKey: Key.speedUnit), let unit = SpeedUnit(rawValue: raw) {
            display.speed = unit
        }
        if let raw = defaults.string(forKey: Key.distanceUnit), let unit = DistanceUnit(rawValue: raw) {
            display.distance = unit
        }
        return display
    }

    /// Whether sessions of this sport are saved to Apple Health (off for motorboating
    /// unless the user turns it on, PLAN §5).
    static func savesWorkout(for sport: Sport) -> Bool {
        defaults.object(forKey: Key.saveWorkout(sport)) == nil
            ? SportProfile.standard(for: sport).savesWorkoutByDefault
            : defaults.bool(forKey: Key.saveWorkout(sport))
    }

    /// The sport's engine profile with the user's auto-pause choice applied.
    static func profile(for sport: Sport) -> SportProfile {
        var profile = SportProfile.standard(for: sport)
        if defaults.object(forKey: Key.autoPause(sport)) != nil {
            profile.autoPause.enabled = defaults.bool(forKey: Key.autoPause(sport))
        }
        return profile
    }
}
