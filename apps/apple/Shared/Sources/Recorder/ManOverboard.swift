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
    static let shared = ManOverboard(defaults: .standard)

    /// A position is current for this long, s. Older ones are shown as stale.
    nonisolated static let freshFor: TimeInterval = 10
    /// Course is used for the arrow only at or above this speed, m/s.
    nonisolated static let minSpeedForCourse = 0.5
    /// How many cleared mark IDs the phone remembers.
    nonisolated static let clearedLimit = 50

    struct Mark: Codable, Equatable, Sendable {
        /// Identifies the mark across devices and relaunches. Nil only in marks saved or
        /// sent by builds before IDs; `identity` stands in for it then.
        var id: UUID?
        var latitude: Double
        var longitude: Double
        /// When MOB was pressed.
        var markedAt: Date
        /// When the marked position was measured: earlier than `markedAt` if GPS was
        /// stale, later if there was no position yet and MOB waited for the first one.
        var positionAt: Date
        /// How old the position was when it was marked, s, from the fix's own timestamp.
        var positionAge: TimeInterval

        init(
            id: UUID? = UUID(), latitude: Double, longitude: Double, markedAt: Date, positionAt: Date,
            positionAge: TimeInterval
        ) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.markedAt = markedAt
            self.positionAt = positionAt
            self.positionAge = positionAge
        }

        /// `id`, or for a mark without one, an ID derived from its exact stored values, so
        /// the same decoded mark always has the same identity. Never compared by time.
        var identity: UUID {
            if let id { return id }
            var bytes = [UInt8](repeating: 0, count: 16)
            let parts = [latitude.bitPattern, longitude.bitPattern, markedAt.timeIntervalSinceReferenceDate.bitPattern]
            for (index, part) in parts.enumerated() {
                for byte in 0..<8 {
                    bytes[(index * 8 + byte) % 16] ^= UInt8(truncatingIfNeeded: part >> (byte * 8))
                }
            }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }

        /// Whether the marked position was older than a fresh one when MOB was pressed.
        var isFromStalePosition: Bool { positionAge > ManOverboard.freshFor }
    }

    struct Position: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        /// When the fix was measured (`CLLocation.timestamp`).
        var at: Date
        /// Doppler speed, m/s, and course over ground, degrees true, when known.
        var speed: Double?
        var course: Double?
        /// `ProcessInfo.systemUptime` when the position arrived.
        var receivedUptime: TimeInterval
        /// How old the fix already was when it arrived, s: the wall clock at arrival minus
        /// the fix's timestamp. A fix delivered late counts as old from the start.
        var ageAtReceipt: TimeInterval

        init(
            latitude: Double, longitude: Double, at: Date, speed: Double? = nil, course: Double? = nil,
            receivedAt: Date = Date(), receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.at = at
            self.speed = speed
            self.course = course
            self.receivedUptime = receivedUptime
            ageAtReceipt = max(0, receivedAt.timeIntervalSince(at))
        }

        /// The fix's age now, s: its age on arrival plus the monotonic time since, so a
        /// later change to the device clock cannot make it look fresh.
        func age(atUptime uptime: TimeInterval) -> TimeInterval {
            ageAtReceipt + max(0, uptime - receivedUptime)
        }
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

    /// The watch mark the phone took, and the watch recording it came from.
    struct Adopted: Codable, Equatable, Sendable {
        var markID: UUID
        var sessionID: UUID
    }

    /// The outcome of a MOB press.
    enum MarkResult: Equatable {
        case marked(Mark)
        /// No position yet: the press is kept and marks the first fix to arrive.
        case awaitingFix
    }

    private enum Key {
        static let mark = "manOverboard.mark"
        static let cleared = "manOverboard.clearedIDs"
        static let adopted = "manOverboard.adoptedWatchMark"
        static let awaitingSince = "manOverboard.awaitingFixSince"
    }

    private let defaults: UserDefaults
    private(set) var mark: Mark?
    /// When MOB was pressed with no position to mark, until the first fix arrives.
    private(set) var awaitingFixSince: Date?
    /// The latest accepted position from a session or this object's own updates.
    private(set) var position: Position?
    private var updates: Task<Void, Never>?
    /// Screens that need this object's own location updates (see `setOwnUpdates`).
    private var ownUpdateOwners: Set<String> = []
    private var clearedIDs: [UUID]
    private var adopted: Adopted?

    /// A mark is set, or a press is waiting for its first position.
    var isActive: Bool { mark != nil || awaitingFixSince != nil }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        #if DEBUG
            // UI tests start without a mark left by an earlier test.
            if ProcessInfo.processInfo.arguments.contains("-resetManOverboard") {
                for key in [Key.mark, Key.cleared, Key.adopted, Key.awaitingSince] { defaults.removeObject(forKey: key) }
            }
        #endif
        let decoder = JSONDecoder()
        mark = defaults.data(forKey: Key.mark).flatMap { try? decoder.decode(Mark.self, from: $0) }
        clearedIDs = defaults.data(forKey: Key.cleared).flatMap { try? decoder.decode([UUID].self, from: $0) } ?? []
        adopted = defaults.data(forKey: Key.adopted).flatMap { try? decoder.decode(Adopted.self, from: $0) }
        awaitingFixSince = (defaults.object(forKey: Key.awaitingSince) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// Fed by the recorder with every accepted fix, and by this object's own updates. A
    /// press waiting for a position marks the first one.
    func update(_ position: Position) {
        self.position = position
        guard let pressedAt = awaitingFixSince else { return }
        set(Self.makeMark(from: position, markedAt: pressedAt, uptime: ProcessInfo.processInfo.systemUptime))
        setAwaiting(nil)
        Haptics.play(.manOverboard)
        if ownUpdateOwners.isEmpty { stopOwnUpdates() }
    }

    /// Marks the latest known position, even a stale one (the screen then says how old it
    /// is). Returns nil when no position has ever been seen.
    func markNow(at now: Date = Date()) -> Mark? {
        guard let position else { return nil }
        let mark = Self.makeMark(from: position, markedAt: now, uptime: ProcessInfo.processInfo.systemUptime)
        set(mark)
        setAwaiting(nil)
        return mark
    }

    /// A MOB press: marks the latest position, or with none yet, waits for the first fix
    /// (from a session or this object's own location updates) and marks that.
    func press(at now: Date = Date()) -> MarkResult {
        if let mark = markNow(at: now) { return .marked(mark) }
        setAwaiting(now)
        startOwnUpdates()
        return .awaitingFix
    }

    nonisolated static func makeMark(from position: Position, markedAt: Date, uptime: TimeInterval) -> Mark {
        Mark(
            latitude: position.latitude, longitude: position.longitude, markedAt: markedAt, positionAt: position.at,
            positionAge: position.age(atUptime: uptime))
    }

    func clear() {
        if let mark { remember(cleared: mark.identity) }
        set(nil)
        setAwaiting(nil)
        stopOwnUpdates()
        ownUpdateOwners.removeAll()
    }

    func isFresh() -> Bool {
        guard let position else { return false }
        return Self.isFresh(position, atUptime: ProcessInfo.processInfo.systemUptime)
    }

    nonisolated static func isFresh(_ position: Position, atUptime uptime: TimeInterval) -> Bool {
        position.age(atUptime: uptime) <= freshFor
    }

    /// The current position's age, s, or nil with none.
    func positionAge() -> TimeInterval? {
        position?.age(atUptime: ProcessInfo.processInfo.systemUptime)
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

    // MARK: Following the watch

    /// Applies the mark from an accepted mirrored watch snapshot (`mirrorUpdate`). Returns
    /// whether it adopted a new mark.
    @discardableResult
    func applyMirrored(_ incoming: Mark?, sessionID: UUID) -> Bool {
        switch Self.mirrorUpdate(
            incoming: incoming, sessionID: sessionID, local: mark, adopted: adopted, cleared: Set(clearedIDs))
        {
        case .keep:
            return false
        case .adopt(let new):
            set(new)
            setAwaiting(nil)
            setAdopted(Adopted(markID: new.identity, sessionID: sessionID))
            return true
        case .clear:
            clear()
            setAdopted(nil)
            return false
        }
    }

    /// How the phone follows the watch's mark during a mirrored session, by mark ID only.
    /// A watch mark is adopted unless the phone cleared it, already holds it, or already
    /// took it once (and has since replaced it with its own). The phone clears the mark it
    /// took from the watch once a snapshot from the same recording no longer carries it,
    /// including after a relaunch. A snapshot without the field (an older watch app)
    /// never took a mark, so it never clears one.
    nonisolated static func mirrorUpdate(
        incoming: Mark?, sessionID: UUID, local: Mark?, adopted: Adopted?, cleared: Set<UUID>
    ) -> MirrorUpdate {
        guard let incoming else {
            if let adopted, adopted.sessionID == sessionID, local?.identity == adopted.markID { return .clear }
            return .keep
        }
        let id = incoming.identity
        if cleared.contains(id) || local?.identity == id || adopted?.markID == id { return .keep }
        return .adopt(incoming)
    }

    // MARK: Own location updates

    /// Own location updates while at least one owner (a screen showing guidance with no
    /// session feeding positions) wants them, so one screen disappearing after another
    /// appears does not stop them.
    func setOwnUpdates(_ wanted: Bool, owner: String) {
        if wanted { ownUpdateOwners.insert(owner) } else { ownUpdateOwners.remove(owner) }
        if ownUpdateOwners.isEmpty && awaitingFixSince == nil { stopOwnUpdates() } else { startOwnUpdates() }
    }

    /// Location updates for guidance, or for a press waiting for a position, when no
    /// session is running. Demo builds for UI tests (`DemoFeed`) use no real location:
    /// they get a still boat at the demo origin instead.
    func startOwnUpdates() {
        guard isActive, updates == nil else { return }
        if DemoFeed.isEnabled {
            updates = Task { [weak self] in
                while !Task.isCancelled {
                    self?.update(Position(latitude: DemoFeed.origin.lat, longitude: DemoFeed.origin.lon, at: Date()))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return
        }
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

    // MARK: Storage

    private func set(_ mark: Mark?) {
        self.mark = mark
        if let mark, let data = try? JSONEncoder().encode(mark) {
            defaults.set(data, forKey: Key.mark)
        } else {
            defaults.removeObject(forKey: Key.mark)
        }
    }

    private func setAwaiting(_ date: Date?) {
        awaitingFixSince = date
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: Key.awaitingSince)
        } else {
            defaults.removeObject(forKey: Key.awaitingSince)
        }
    }

    private func remember(cleared id: UUID) {
        clearedIDs.removeAll { $0 == id }
        clearedIDs.append(id)
        clearedIDs = Array(clearedIDs.suffix(Self.clearedLimit))
        if let data = try? JSONEncoder().encode(clearedIDs) { defaults.set(data, forKey: Key.cleared) }
    }

    private func setAdopted(_ adopted: Adopted?) {
        self.adopted = adopted
        if let adopted, let data = try? JSONEncoder().encode(adopted) {
            defaults.set(data, forKey: Key.adopted)
        } else {
            defaults.removeObject(forKey: Key.adopted)
        }
    }
}
