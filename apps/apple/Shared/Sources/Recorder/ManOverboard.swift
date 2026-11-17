import CoreLocation
import Foundation
import Observation
import WaterKit

/// The man-overboard mark and the way back to it (docs/PLAN.md §5). It lives outside any
/// session: the mark is saved until the user clears it, so it survives ending the session
/// and relaunching the app, and it keeps its own location updates when no session is
/// feeding it positions.
@MainActor
@Observable
final class ManOverboard {
    static let shared = ManOverboard()

    /// A position is current for this long, s. Older ones are shown as stale.
    static let freshFor: TimeInterval = 10
    /// Course is used for the arrow only at or above this speed, m/s.
    static let minSpeedForCourse = 0.5

    struct Mark: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        /// When MOB was pressed.
        var markedAt: Date
        /// When the marked position was measured; earlier than `markedAt` if GPS was stale.
        var positionAt: Date

        /// How old the position was when MOB was pressed, s.
        var positionAge: TimeInterval { markedAt.timeIntervalSince(positionAt) }
    }

    struct Position: Equatable {
        var latitude: Double
        var longitude: Double
        var at: Date
        /// Doppler speed, m/s, and course over ground, degrees true, when known.
        var speed: Double?
        var course: Double?
    }

    struct Guidance: Equatable {
        var distance: Double
        /// True bearing to the mark, degrees.
        var bearing: Double
        /// Arrow rotation: relative to course while moving, else from true north.
        var arrow: Double
        var isCourseRelative: Bool
    }

    private static let storageKey = "manOverboard.mark"

    private(set) var mark: Mark?
    /// The latest accepted position from a session or this object's own updates.
    private(set) var position: Position?
    private var updates: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey) {
            mark = try? JSONDecoder().decode(Mark.self, from: data)
        }
    }

    /// Fed by the recorder with every accepted fix.
    func update(_ position: Position) {
        self.position = position
    }

    /// Marks the latest known position. Returns nil when no position has ever been seen.
    func markNow(at now: Date = Date()) -> Mark? {
        guard let position else { return nil }
        let mark = Mark(
            latitude: position.latitude, longitude: position.longitude, markedAt: now, positionAt: position.at)
        set(mark)
        return mark
    }

    func clear() {
        set(nil)
        stopOwnUpdates()
    }

    func isFresh(at now: Date = Date()) -> Bool {
        guard let position else { return false }
        return now.timeIntervalSince(position.at) <= Self.freshFor
    }

    /// Distance and arrow to the mark from a current position; nil when there is no mark
    /// or the position is stale, so the screen never shows guidance from an old fix.
    func guidance(at now: Date = Date()) -> Guidance? {
        guard let mark, let position, isFresh(at: now) else { return nil }
        let distance = Geo.distance(
            lat1: position.latitude, lon1: position.longitude, lat2: mark.latitude, lon2: mark.longitude)
        let bearing = Geo.bearing(
            lat1: position.latitude, lon1: position.longitude, lat2: mark.latitude, lon2: mark.longitude)
        if let course = position.course, let speed = position.speed, speed >= Self.minSpeedForCourse {
            return Guidance(distance: distance, bearing: bearing, arrow: bearing - course, isCourseRelative: true)
        }
        return Guidance(distance: distance, bearing: bearing, arrow: bearing, isCourseRelative: false)
    }

    /// Location updates for guidance when no session is running.
    func startOwnUpdates() {
        guard mark != nil, updates == nil else { return }
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if Task.isCancelled { break }
                    guard let location = update.location, location.horizontalAccuracy >= 0,
                        location.horizontalAccuracy <= 25
                    else { continue }
                    self?.update(
                        Position(
                            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                            at: location.timestamp, speed: location.speed >= 0 ? location.speed : nil,
                            course: location.course >= 0 ? location.course : nil))
                }
            } catch {
                print("ManOverboard: location updates ended: \(error)")
            }
        }
    }

    func stopOwnUpdates() {
        updates?.cancel()
        updates = nil
    }

    private func set(_ mark: Mark?) {
        self.mark = mark
        if let mark, let data = try? JSONEncoder().encode(mark) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }
}
