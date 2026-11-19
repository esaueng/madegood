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
    nonisolated static let freshFor: TimeInterval = 10
    /// Course is used for the arrow only at or above this speed, m/s.
    nonisolated static let minSpeedForCourse = 0.5

    struct Mark: Codable, Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        /// When MOB was pressed.
        var markedAt: Date
        /// When the marked position was measured; earlier than `markedAt` if GPS was stale.
        var positionAt: Date
        /// How old the position was when MOB was pressed, s, measured on the monotonic
        /// uptime clock so a change to the device clock cannot hide its age.
        var positionAge: TimeInterval
    }

    struct Position: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var at: Date
        /// Doppler speed, m/s, and course over ground, degrees true, when known.
        var speed: Double?
        var course: Double?
        /// `ProcessInfo.systemUptime` when the position arrived. Freshness uses this, not
        /// `at`: the wall clock can be set backward, uptime cannot.
        var receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    }

    struct Guidance: Equatable, Sendable {
        var distance: Double
        /// True bearing to the mark, degrees.
        var bearing: Double
        /// Arrow rotation: relative to course while moving, else from true north.
        var arrow: Double
        var isCourseRelative: Bool
    }

    /// What the phone does with the mark in a mirrored watch snapshot.
    enum MirrorUpdate: Equatable {
        case keep
        case adopt(Mark)
        case clear
    }

    private static let storageKey = "manOverboard.mark"
    /// `markedAt` of the last mark cleared on this device, so a mirrored watch snapshot
    /// that still carries it does not bring it back.
    private static let clearedKey = "manOverboard.clearedMarkedAt"

    private(set) var mark: Mark?
    /// The latest accepted position from a session or this object's own updates.
    private(set) var position: Position?
    private var updates: Task<Void, Never>?
    /// Screens that need this object's own location updates (see `setOwnUpdates`).
    private var ownUpdateOwners: Set<String> = []

    private init() {
        #if DEBUG
            // UI tests start without a mark left by an earlier test.
            if ProcessInfo.processInfo.arguments.contains("-resetManOverboard") {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
                UserDefaults.standard.removeObject(forKey: Self.clearedKey)
            }
        #endif
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
            latitude: position.latitude, longitude: position.longitude, markedAt: now, positionAt: position.at,
            positionAge: age(of: position))
        set(mark)
        return mark
    }

    func clear() {
        if let mark {
            UserDefaults.standard.set(mark.markedAt.timeIntervalSince1970, forKey: Self.clearedKey)
        }
        set(nil)
        stopOwnUpdates()
        ownUpdateOwners.removeAll()
    }

    /// Applies the mark from a mirrored watch snapshot (`mirrorUpdate`). Returns whether
    /// it adopted a new mark.
    @discardableResult
    func applyMirrored(_ incoming: Mark?, previous: Mark?) -> Bool {
        let cleared = UserDefaults.standard.object(forKey: Self.clearedKey) as? Double
        switch Self.mirrorUpdate(
            incoming: incoming, previous: previous, local: mark,
            clearedMarkedAt: cleared.map { Date(timeIntervalSince1970: $0) })
        {
        case .keep: return false
        case .adopt(let new):
            set(new)
            return true
        case .clear:
            clear()
            return false
        }
    }

    /// How the phone follows the watch's mark during a mirrored session. `previous` is the
    /// mark in the same recording's previous snapshot. A new watch mark is adopted unless
    /// the phone cleared it or holds a newer one; the phone clears a mark it took from the
    /// watch once the watch clears it. A snapshot without the field (an older watch app)
    /// never changes anything.
    nonisolated static func mirrorUpdate(
        incoming: Mark?, previous: Mark?, local: Mark?, clearedMarkedAt: Date?
    ) -> MirrorUpdate {
        guard let incoming else {
            if let previous, local == previous { return .clear }
            return .keep
        }
        if incoming == previous || incoming == local { return .keep }
        if let clearedMarkedAt, incoming.markedAt <= clearedMarkedAt { return .keep }
        if let local, local.markedAt > incoming.markedAt { return .keep }
        return .adopt(incoming)
    }

    func isFresh() -> Bool {
        guard let position else { return false }
        return age(of: position) <= Self.freshFor
    }

    private func age(of position: Position) -> TimeInterval {
        max(0, ProcessInfo.processInfo.systemUptime - position.receivedUptime)
    }

    /// Distance and arrow to the mark from a current position; nil when there is no mark
    /// or the position is stale, so the screen never shows guidance from an old fix.
    func guidance() -> Guidance? {
        guard let mark, let position, isFresh() else { return nil }
        return Self.guidance(from: position, to: mark)
    }

    /// Distance, bearing and arrow from a position to the mark, whatever the position's age.
    nonisolated static func guidance(from position: Position, to mark: Mark) -> Guidance {
        let distance = Geo.distance(
            lat1: position.latitude, lon1: position.longitude, lat2: mark.latitude, lon2: mark.longitude)
        let bearing = Geo.bearing(
            lat1: position.latitude, lon1: position.longitude, lat2: mark.latitude, lon2: mark.longitude)
        if let course = position.course, let speed = position.speed, speed >= minSpeedForCourse {
            return Guidance(distance: distance, bearing: bearing, arrow: bearing - course, isCourseRelative: true)
        }
        return Guidance(distance: distance, bearing: bearing, arrow: bearing, isCourseRelative: false)
    }

    /// Own location updates while at least one owner (a screen showing guidance with no
    /// session feeding positions) wants them, so one screen disappearing after another
    /// appears does not stop them.
    func setOwnUpdates(_ wanted: Bool, owner: String) {
        if wanted { ownUpdateOwners.insert(owner) } else { ownUpdateOwners.remove(owner) }
        if ownUpdateOwners.isEmpty { stopOwnUpdates() } else { startOwnUpdates() }
    }

    /// Location updates for guidance when no session is running. Demo builds for UI tests
    /// (`DemoFeed`) use no real location, so they never ask for it here.
    func startOwnUpdates() {
        guard mark != nil, updates == nil, !DemoFeed.isEnabled else { return }
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
