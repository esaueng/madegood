import CoreLocation
import Foundation
import Observation
import WaterKit

/// The man-overboard marks and the way back (docs/PLAN.md §5). They live outside any
/// session: marks are saved until the user clears them, so they survive ending the session
/// and relaunching the app, and this object keeps its own location updates when no
/// session is feeding it positions.
///
/// There can be more than one mark (a press on this device and one from the watch, or a
/// second person overboard). The guidance target is the mark added last; the others stay
/// listed until cleared.
@MainActor
@Observable
final class ManOverboard {
    static let shared = ManOverboard(defaults: .standard)

    /// A position is current for this long, s. Older ones are shown as stale.
    nonisolated static let freshFor: TimeInterval = 10
    /// Course is used for the arrow only at or above this speed, m/s.
    nonisolated static let minSpeedForCourse = 0.5
    /// How many cleared and adopted mark records the phone remembers.
    nonisolated static let memoryLimit = 50
    /// The most marks kept at once. A mark beyond it is refused, never evicting another.
    nonisolated static let markLimit = 50
    /// A press still waiting for a fix after this long marks the last known position, s.
    nonisolated static let fallbackAfter: TimeInterval = 15
    /// The last known position is used for that only when this recent, s, and this
    /// accurate, m.
    nonisolated static let fallbackMaxAge: TimeInterval = 120
    nonisolated static let fallbackMaxAccuracy: Double = 50
    /// A fresh fix this soon after the press replaces an approximate mark's position, s.
    nonisolated static let refineWindow: TimeInterval = 120
    /// Marks pressed this close together count as simultaneous when choosing the target;
    /// this device's own mark wins then, s.
    nonisolated static let targetTieWindow: TimeInterval = 5

    enum Origin: String, Codable, Sendable {
        /// Taken from the watch's mirrored session.
        case watch
    }

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
        /// Where the mark came from; nil when it was marked on this device.
        var origin: Origin?
        /// The watch recording an adopted mark came from.
        var recordingID: UUID?
        /// Marked from a cached last known position after no fix arrived: shown as
        /// approximate, and never the target over a mark from a real fix.
        var isApproximate: Bool?

        init(
            id: UUID? = UUID(), latitude: Double, longitude: Double, markedAt: Date, positionAt: Date,
            positionAge: TimeInterval, origin: Origin? = nil, recordingID: UUID? = nil, isApproximate: Bool? = nil
        ) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.markedAt = markedAt
            self.positionAt = positionAt
            self.positionAge = positionAge
            self.origin = origin
            self.recordingID = recordingID
            self.isApproximate = isApproximate
        }

        /// `id`, or for a mark without one, an ID derived from its exact stored values
        /// (position, press time, fix time and age), so the same decoded mark always has
        /// the same identity. Never compared by time.
        var identity: UUID {
            if let id { return id }
            var bytes = [UInt8](repeating: 0, count: 16)
            let parts = [
                latitude.bitPattern, longitude.bitPattern, markedAt.timeIntervalSinceReferenceDate.bitPattern,
                positionAt.timeIntervalSinceReferenceDate.bitPattern, positionAge.bitPattern,
            ]
            for (index, part) in parts.enumerated() {
                // Rotate each part so equal fields in different places do not cancel out.
                let rotated = part << UInt64(index * 13 % 64) | part >> UInt64((64 - index * 13 % 64) % 64)
                for byte in 0..<8 {
                    bytes[(index * 8 + byte) % 16] ^= UInt8(truncatingIfNeeded: rotated >> (byte * 8))
                }
            }
            return UUID(
                uuid: (
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
        /// Horizontal accuracy, m, when known.
        var accuracy: Double?

        init(
            latitude: Double, longitude: Double, at: Date, speed: Double? = nil, course: Double? = nil,
            accuracy: Double? = nil, receivedAt: Date = Date(),
            receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.at = at
            self.speed = speed
            self.course = course
            self.accuracy = accuracy
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

    /// Why this device cannot get the positions it needs.
    enum LocationIssue: String, Equatable, Sendable {
        case denied
        case restricted
        /// Approximate location only: too coarse to mark or steer back.
        case reducedAccuracy
        case unavailable
    }

    /// A watch mark the phone took: from which recording, and the snapshot sequence that
    /// delivered it. Only a later snapshot of that recording may clear it.
    struct Adopted: Codable, Equatable, Sendable {
        var markID: UUID
        var sessionID: UUID
        var sequence: UInt64
    }

    /// A mark cleared on this device. Legacy IDs (derived from a mark's values) are
    /// scoped to the watch recording they came from; real IDs are global.
    struct Cleared: Codable, Equatable, Hashable, Sendable {
        var markID: UUID
        var recordingID: UUID?

        func matches(_ mark: Mark, recording: UUID?) -> Bool {
            guard markID == mark.identity else { return false }
            return mark.id != nil || recordingID == recording
        }
    }

    /// What the phone does with the watch's marks in one mirrored snapshot.
    struct MirrorUpdate: Equatable {
        var adopt: [Mark] = []
        /// IDs of adopted watch marks the watch has explicitly cleared.
        var clear: [UUID] = []
        var isEmpty: Bool { adopt.isEmpty && clear.isEmpty }
    }

    /// The outcome of a MOB press.
    enum MarkResult: Equatable {
        case marked(Mark)
        /// No position yet: the press is kept and marks the first fix to arrive, or a
        /// recent, accurate last known position after `fallbackAfter`.
        case awaitingFix
        /// `markLimit` marks are already set: nothing was marked (`notice` says so).
        case full
    }

    private enum Key {
        static let legacyMark = "manOverboard.mark"
        static let marks = "manOverboard.marks"
        static let cleared = "manOverboard.cleared"
        static let adopted = "manOverboard.adopted"
        static let awaitingSince = "manOverboard.awaitingFixSince"
        static let all = [legacyMark, marks, cleared, adopted, awaitingSince]
    }

    private let defaults: UserDefaults
    /// Every mark, in the order added; the last is the guidance target.
    private(set) var marks: [Mark]
    /// When MOB was pressed on this device with no position to mark, until a fix arrives.
    private(set) var awaitingFixSince: Date?
    /// The latest accepted position from a session or this object's own updates.
    private(set) var position: Position?
    /// Location denied, restricted, approximate or unavailable, from this object's own
    /// updates or from a recording's (`setRecorderLocationIssue`).
    var locationIssue: LocationIssue? { ownLocationIssue ?? recorderLocationIssue }
    private var ownLocationIssue: LocationIssue?
    private var recorderLocationIssue: LocationIssue?
    /// A short message for the MOB screens: another mark arrived without becoming the
    /// target, or a mark was refused at `markLimit`. Cleared with `dismissNotice`.
    private(set) var notice: String?
    /// A manual "Steer to this" choice; otherwise the target is chosen by press time.
    private var pinnedTargetID: UUID?
    private var updates: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    #if os(iOS)
        /// Keeps own updates coming while the phone is locked.
        private var backgroundSession: CLBackgroundActivitySession?
    #endif
    private var serviceSession: CLServiceSession?
    /// Screens that need this object's own location updates (see `setOwnUpdates`).
    private var ownUpdateOwners: Set<String> = []
    private var cleared: [Cleared]
    private var adopted: [Adopted]
    /// The last known position when a waiting press times out; CoreLocation's cached fix
    /// by default. Tests replace it.
    var lastKnownPosition: @MainActor () -> Position? = { ManOverboard.cachedSystemPosition() }

    /// The guidance target: a mark picked with "Steer to this", else the newest by press
    /// time (`targetIndex`), so a delayed older mark never takes over on arrival.
    var mark: Mark? { Self.targetIndex(in: marks, pinned: pinnedTargetID).map { marks[$0] } }
    /// The marks other than the target, newest press first.
    var otherMarks: [Mark] {
        guard let target = mark else { return [] }
        return marks.filter { $0.identity != target.identity }.sorted { $0.markedAt > $1.markedAt }
    }
    /// IDs of the marks cleared on this device, most recent last (sent to the phone).
    var clearedMarkIDs: [UUID] { cleared.map(\.markID) }
    /// A mark is set, or a press is waiting for its first position.
    var isActive: Bool { !marks.isEmpty || awaitingFixSince != nil }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        #if DEBUG
            // UI tests start without a mark left by an earlier test.
            if ProcessInfo.processInfo.arguments.contains("-resetManOverboard") {
                for key in Key.all { defaults.removeObject(forKey: key) }
            }
        #endif
        let decoder = JSONDecoder()
        if let saved = defaults.data(forKey: Key.marks).flatMap({ try? decoder.decode([Mark].self, from: $0) }) {
            marks = saved
        } else {
            // A single mark saved before marks were a list.
            marks =
                defaults.data(forKey: Key.legacyMark).flatMap { try? decoder.decode(Mark.self, from: $0) }
                .map { [$0] } ?? []
        }
        cleared = defaults.data(forKey: Key.cleared).flatMap { try? decoder.decode([Cleared].self, from: $0) } ?? []
        adopted = defaults.data(forKey: Key.adopted).flatMap { try? decoder.decode([Adopted].self, from: $0) } ?? []
        // Stored as a Date, not seconds since 1970, so it reads back exactly.
        awaitingFixSince = defaults.object(forKey: Key.awaitingSince) as? Date
    }

    /// Fed by the recorder with every accepted fix, and by this object's own updates. A
    /// press waiting for a position marks the first one, as its own mark; a fresh fix soon
    /// after an approximate mark replaces its position.
    func update(_ position: Position) {
        self.position = position
        if let pressedAt = awaitingFixSince {
            resolveAwaiting(pressedAt: pressedAt, with: position)
        } else {
            refineApproximate(with: position)
        }
    }

    private func resolveAwaiting(pressedAt: Date, with position: Position, approximate: Bool = false) {
        var mark = Self.makeMark(from: position, markedAt: pressedAt, uptime: ProcessInfo.processInfo.systemUptime)
        if approximate { mark.isApproximate = true }
        guard add(mark) else { return }
        setAwaiting(nil)
        fallback?.cancel()
        fallback = nil
        Haptics.play(.manOverboard)
        // An approximate mark keeps updates running for the fix that refines it.
        if ownUpdateOwners.isEmpty && !approximate { stopOwnUpdates() }
    }

    /// Replaces an approximate mark's position with the first fresh fix within
    /// `refineWindow` of its press.
    private func refineApproximate(with position: Position) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard Self.isFresh(position, atUptime: uptime),
            let index = marks.firstIndex(where: {
                $0.isApproximate == true && $0.origin == nil
                    && position.at.timeIntervalSince($0.markedAt) <= Self.refineWindow
            })
        else { return }
        var refined = Self.makeMark(from: position, markedAt: marks[index].markedAt, uptime: uptime)
        refined.id = marks[index].id
        var updated = marks
        updated[index] = refined
        setMarks(updated)
    }

    /// Marks the latest known position, even a stale one (the screen then says how old it
    /// is). Returns nil when no position has ever been seen.
    func markNow(at now: Date = Date()) -> Mark? {
        guard let position else { return nil }
        let mark = Self.makeMark(from: position, markedAt: now, uptime: ProcessInfo.processInfo.systemUptime)
        guard add(mark) else { return nil }
        return mark
    }

    /// A MOB press: marks the latest position, or with none yet, waits for the first fix
    /// (from a session or this object's own location updates) and marks that, falling
    /// back to the last known position after `fallbackAfter`.
    func press(at now: Date = Date()) -> MarkResult {
        refreshLocationIssue()
        guard marks.count < Self.markLimit else {
            refuseFull()
            return .full
        }
        // A new press on this device is the target, even over a "Steer to this" choice.
        pinnedTargetID = nil
        if let mark = markNow(at: now) { return .marked(mark) }
        setAwaiting(now)
        startOwnUpdates()
        scheduleFallback()
        return .awaitingFix
    }

    /// Marks a waiting press at the last known position, as an approximate mark with its
    /// age, if one is recent and accurate enough (`isUsableFallback`). Returns whether it
    /// marked; otherwise the press keeps waiting.
    @discardableResult
    func resolveAwaitingWithLastKnown() -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let pressedAt = awaitingFixSince,
            let last = [position, lastKnownPosition()].compactMap({ $0 })
                .first(where: { Self.isUsableFallback($0, atUptime: uptime) })
        else { return false }
        resolveAwaiting(pressedAt: pressedAt, with: last, approximate: true)
        return true
    }

    nonisolated static func isUsableFallback(_ position: Position, atUptime uptime: TimeInterval) -> Bool {
        guard let accuracy = position.accuracy, accuracy >= 0, accuracy <= fallbackMaxAccuracy else { return false }
        return position.age(atUptime: uptime) <= fallbackMaxAge
    }

    private func scheduleFallback() {
        fallback?.cancel()
        fallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fallbackAfter))
            guard !Task.isCancelled else { return }
            self?.resolveAwaitingWithLastKnown()
        }
    }

    nonisolated static func makeMark(from position: Position, markedAt: Date, uptime: TimeInterval) -> Mark {
        Mark(
            latitude: position.latitude, longitude: position.longitude, markedAt: markedAt, positionAt: position.at,
            positionAge: position.age(atUptime: uptime))
    }

    /// Clears the guidance target, or with no mark, cancels a waiting press. The next
    /// newest mark becomes the target.
    func clear() {
        if let target = mark {
            remove(target.identity)
        } else {
            setAwaiting(nil)
            fallback?.cancel()
            fallback = nil
        }
        if !isActive {
            stopOwnUpdates()
            ownUpdateOwners.removeAll()
        }
    }

    /// Makes another mark the guidance target ("Steer to this").
    func target(_ markID: UUID) {
        guard marks.contains(where: { $0.identity == markID }) else { return }
        pinnedTargetID = markID
    }

    func dismissNotice() { notice = nil }

    /// The target's index: the pinned mark if present; otherwise marks from a real fix
    /// before approximate ones, then the newest press. Presses within `targetTieWindow`
    /// count as simultaneous and this device's own mark wins; a full tie keeps the
    /// earlier-added mark, so the choice is stable.
    nonisolated static func targetIndex(in marks: [Mark], pinned: UUID?) -> Int? {
        if let pinned, let index = marks.firstIndex(where: { $0.identity == pinned }) { return index }
        func beats(_ a: Mark, _ b: Mark) -> Bool {
            let aReal = a.isApproximate != true
            let bReal = b.isApproximate != true
            if aReal != bReal { return aReal }
            let gap = a.markedAt.timeIntervalSince(b.markedAt)
            if abs(gap) <= targetTieWindow {
                let aLocal = a.origin == nil
                let bLocal = b.origin == nil
                if aLocal != bLocal { return aLocal }
                if gap == 0 { return false }
            }
            return gap > 0
        }
        var best: Int?
        for index in marks.indices where best.map({ beats(marks[index], marks[$0]) }) ?? true {
            best = index
        }
        return best
    }

    private func remove(_ markID: UUID) {
        guard let mark = marks.first(where: { $0.identity == markID }) else { return }
        remember(Cleared(markID: markID, recordingID: mark.id == nil ? mark.recordingID : nil))
        if pinnedTargetID == markID { pinnedTargetID = nil }
        setMarks(marks.filter { $0.identity != markID })
    }

    /// Adds a mark, or refuses it at `markLimit`. Never evicts another mark.
    @discardableResult
    private func add(_ mark: Mark) -> Bool {
        if let index = marks.firstIndex(where: { $0.identity == mark.identity }) {
            var updated = marks
            updated[index] = mark
            setMarks(updated)
            return true
        }
        guard marks.count < Self.markLimit else {
            refuseFull()
            return false
        }
        setMarks(marks + [mark])
        return true
    }

    private func refuseFull() {
        notice = "\(Self.markLimit) marks are set. Clear one to add another."
        Haptics.play(.failure)
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

    /// Distance and arrow to the target mark from a current position; nil when there is
    /// no mark or the position is stale, so the screen never shows guidance from an old fix.
    func guidance() -> Guidance? {
        guard let mark else { return nil }
        return guidance(to: mark)
    }

    func guidance(to mark: Mark) -> Guidance? {
        guard let position, isFresh() else { return nil }
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

    /// Applies the marks from an accepted mirrored watch snapshot (`mirrorUpdate`).
    /// Returns whether it adopted a new mark. A waiting press on this device is never
    /// touched: it still becomes its own mark at its first fix.
    @discardableResult
    func applyMirrored(
        _ incoming: [Mark]?, clearedByWatch: [UUID]? = nil, sessionID: UUID, sequence: UInt64
    ) -> Bool {
        let update = Self.mirrorUpdate(
            incoming: incoming, clearedByWatch: clearedByWatch, sessionID: sessionID, sequence: sequence,
            held: marks, adopted: adopted, cleared: cleared)
        guard !update.isEmpty else { return false }
        for id in update.clear { remove(id) }
        var adoptedAny = false
        for mark in update.adopt {
            var taken = mark
            taken.origin = .watch
            taken.recordingID = sessionID
            guard add(taken) else { break }
            adoptedAny = true
            rememberAdopted(Adopted(markID: mark.identity, sessionID: sessionID, sequence: sequence))
            if mark.identity != self.mark?.identity {
                // An older press arriving late does not take over the arrow.
                notice = "Another mark arrived from Apple Watch."
            }
        }
        if !isActive { stopOwnUpdates() }
        return adoptedAny
    }

    /// How the phone follows the watch's marks, by mark ID only, never by timestamp.
    /// A watch mark is adopted unless the phone cleared it, holds it, or already took it
    /// once. An adopted mark is cleared only when the watch says it cleared it
    /// (`clearedByWatch`), in a snapshot of the same recording with a higher sequence than
    /// the one that delivered it; a mark merely missing from a snapshot is never cleared.
    /// So a cached older snapshot, an older watch app (no fields) or a watch at its mark
    /// limit cannot clear a mark.
    nonisolated static func mirrorUpdate(
        incoming: [Mark]?, clearedByWatch: [UUID]? = nil, sessionID: UUID, sequence: UInt64, held: [Mark],
        adopted: [Adopted], cleared: [Cleared]
    ) -> MirrorUpdate {
        var update = MirrorUpdate()
        let heldIDs = Set(held.map(\.identity))
        let clearedIDs = Set(clearedByWatch ?? [])
        for record in adopted
        where record.sessionID == sessionID && sequence > record.sequence && clearedIDs.contains(record.markID)
            && heldIDs.contains(record.markID)
        {
            update.clear.append(record.markID)
        }
        guard let incoming else { return update }
        for mark in incoming {
            let id = mark.identity
            // A legacy ID (derived from values) only counts within its own recording.
            let takenBefore = adopted.contains { $0.markID == id && (mark.id != nil || $0.sessionID == sessionID) }
            if heldIDs.contains(id) || takenBefore { continue }
            if cleared.contains(where: { $0.matches(mark, recording: sessionID) }) { continue }
            if clearedIDs.contains(id) { continue }
            update.adopt.append(mark)
        }
        return update
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
    /// session is running. They keep coming while the phone is locked (a background
    /// activity session). Demo builds for UI tests (`DemoFeed`) use no real location:
    /// they get a still boat at the demo origin instead, or none with `-demoLocationIssue`.
    func startOwnUpdates() {
        guard isActive, updates == nil else { return }
        refreshLocationIssue()
        if DemoFeed.isEnabled {
            guard Self.demoLocationIssue == nil else { return }
            updates = Task { [weak self] in
                while !Task.isCancelled {
                    self?.update(Position(latitude: DemoFeed.origin.lat, longitude: DemoFeed.origin.lon, at: Date()))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return
        }
        serviceSession = CLServiceSession(authorization: .whenInUse)
        #if os(iOS)
            backgroundSession = CLBackgroundActivitySession()
        #endif
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if Task.isCancelled { break }
                    self?.setLocationIssue(Self.issue(from: update))
                    guard let location = update.location, location.horizontalAccuracy >= 0,
                        location.horizontalAccuracy <= 25
                    else { continue }
                    self?.update(
                        Position(
                            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                            at: location.timestamp, speed: location.speed >= 0 ? location.speed : nil,
                            course: location.course >= 0 ? location.course : nil,
                            accuracy: location.horizontalAccuracy))
                }
            } catch {
                self?.setLocationIssue(.unavailable)
            }
        }
    }

    func stopOwnUpdates() {
        updates?.cancel()
        updates = nil
        serviceSession?.invalidate()
        serviceSession = nil
        #if os(iOS)
            backgroundSession?.invalidate()
            backgroundSession = nil
        #endif
    }

    private func setLocationIssue(_ issue: LocationIssue?) {
        if ownLocationIssue != issue { ownLocationIssue = issue }
    }

    /// A recording's location diagnostics (`LocationSource`), so the MOB surfaces say why
    /// fixes stopped during a session too. Nil when fine or when the recording ends.
    func setRecorderLocationIssue(_ issue: LocationIssue?) {
        if recorderLocationIssue != issue { recorderLocationIssue = issue }
    }

    /// Reads the authorization now, so a denial shows at once rather than after the
    /// first (never-arriving) update.
    private func refreshLocationIssue() {
        if DemoFeed.isEnabled {
            setLocationIssue(Self.demoLocationIssue)
            return
        }
        let manager = CLLocationManager()
        setLocationIssue(Self.issue(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization))
    }

    nonisolated static func issue(
        status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization
    ) -> LocationIssue? {
        switch status {
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedAlways, .authorizedWhenInUse: return accuracy == .reducedAccuracy ? .reducedAccuracy : nil
        case .notDetermined: return nil
        @unknown default: return nil
        }
    }

    nonisolated static func issue(from update: CLLocationUpdate) -> LocationIssue? {
        if update.authorizationDenied || update.authorizationDeniedGlobally { return .denied }
        if update.authorizationRestricted { return .restricted }
        if update.accuracyLimited { return .reducedAccuracy }
        if update.locationUnavailable { return .unavailable }
        return nil
    }

    /// `-demoLocationIssue <denied|restricted|reducedAccuracy|unavailable>` in a Debug demo
    /// build: own updates behave as if location had that problem.
    nonisolated static var demoLocationIssue: LocationIssue? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-demoLocationIssue"), index + 1 < arguments.count else {
                return nil
            }
            return LocationIssue(rawValue: arguments[index + 1])
        #else
            return nil
        #endif
    }

    /// CoreLocation's last cached fix, if any (none in demo builds).
    static func cachedSystemPosition() -> Position? {
        guard !DemoFeed.isEnabled, let location = CLLocationManager().location, location.horizontalAccuracy >= 0
        else { return nil }
        return Position(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, at: location.timestamp,
            accuracy: location.horizontalAccuracy)
    }

    // MARK: Storage

    private func setMarks(_ marks: [Mark]) {
        self.marks = marks
        defaults.removeObject(forKey: Key.legacyMark)
        if marks.isEmpty {
            defaults.removeObject(forKey: Key.marks)
        } else if let data = try? JSONEncoder().encode(marks) {
            defaults.set(data, forKey: Key.marks)
        }
    }

    private func setAwaiting(_ date: Date?) {
        awaitingFixSince = date
        if let date {
            defaults.set(date, forKey: Key.awaitingSince)
        } else {
            defaults.removeObject(forKey: Key.awaitingSince)
        }
    }

    private func remember(_ record: Cleared) {
        cleared = Array((cleared.filter { $0 != record } + [record]).suffix(Self.memoryLimit))
        if let data = try? JSONEncoder().encode(cleared) { defaults.set(data, forKey: Key.cleared) }
    }

    private func rememberAdopted(_ record: Adopted) {
        adopted = Array((adopted.filter { $0.markID != record.markID } + [record]).suffix(Self.memoryLimit))
        if let data = try? JSONEncoder().encode(adopted) { defaults.set(data, forKey: Key.adopted) }
    }
}
