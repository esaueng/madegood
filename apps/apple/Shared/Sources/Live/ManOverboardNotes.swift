import Foundation

/// Plain-language notes on how much to trust a man-overboard mark and the current
/// position, shared by the watch and phone screens.
enum ManOverboardNotes {
    /// Why the marked position may not be where MOB was pressed, or nil when it is a
    /// fresh fix from the moment of the press.
    static func markQuality(_ mark: ManOverboard.Mark) -> String? {
        if mark.isApproximate == true {
            return "Approximate mark — \(Formatting.duration(mark.positionAge)) old"
        }
        // Both times come from the device that marked, so they compare on one clock.
        let after = mark.positionAt.timeIntervalSince(mark.markedAt)
        if after > 1 {
            return "Position from \(Formatting.duration(after)) after MOB was pressed"
        }
        if mark.isFromStalePosition {
            return "Marked from a position \(Formatting.duration(mark.positionAge)) old"
        }
        return nil
    }

    /// Why this device cannot mark or steer back, and what to do about it.
    static func locationIssue(_ issue: ManOverboard.LocationIssue) -> String {
        switch issue {
        case .denied: "Location access is off. Allow it in Settings."
        case .restricted: "Location is restricted on this device."
        case .reducedAccuracy: "Precise location is off. Turn it on in Settings."
        case .unavailable: "Location is unavailable."
        }
    }

    /// Which device marked the target, when that is worth saying.
    static func origin(_ mark: ManOverboard.Mark) -> String {
        mark.origin == .watch ? "Marked on Apple Watch" : "Marked on this device"
    }

    /// Why there is no guidance now: no position yet, or the last one is too old.
    static func waiting(positionAge: TimeInterval?, hasMark: Bool) -> String {
        guard hasMark else { return "Getting a position to mark" }
        guard let positionAge else { return "Waiting for GPS" }
        return "No GPS — last fix \(Formatting.duration(positionAge)) ago"
    }
}
