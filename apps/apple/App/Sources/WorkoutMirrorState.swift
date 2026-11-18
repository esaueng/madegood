import Foundation

/// Tracks the HealthKit connection separately from the watch's recording UUID.
struct WorkoutMirrorState {
    static let staleAfter: TimeInterval = 15

    private var connection: ObjectIdentifier?
    private var confirmed = false
    private var dismissed = false
    private var lastActivityAt: Date?
    private var retiredSessions: Set<UUID> = []
    private(set) var lastConfirmed: WorkoutMirrorSnapshot?

    var isAttached: Bool { connection != nil && !dismissed }
    var connectedSnapshot: WorkoutMirrorSnapshot? { isAttached && confirmed ? lastConfirmed : nil }

    mutating func connect(_ connection: ObjectIdentifier, at now: Date = .now) {
        guard self.connection != connection else { return }
        self.connection = connection
        confirmed = false
        dismissed = false
        lastActivityAt = now
    }

    mutating func receive(_ snapshot: WorkoutMirrorSnapshot, from connection: ObjectIdentifier, at now: Date = .now) {
        guard isAttached, self.connection == connection, snapshot.version == WorkoutMirrorSnapshot.currentVersion,
            !retiredSessions.contains(snapshot.sessionID)
        else { return }

        if let lastConfirmed {
            if snapshot.sessionID == lastConfirmed.sessionID {
                guard snapshot.sequence > lastConfirmed.sequence, snapshot.sport == lastConfirmed.sport else { return }
            } else {
                // A connection can only speak for the recording that first claimed it.
                guard !confirmed else { return }
                retiredSessions.insert(lastConfirmed.sessionID)
            }
        }

        lastConfirmed = snapshot
        confirmed = true
        lastActivityAt = now
    }

    func isStale(at now: Date) -> Bool {
        guard isAttached, let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) >= Self.staleAfter
    }

    mutating func dismissIfStale(at now: Date) {
        if isStale(at: now) { dismissed = true }
    }

    mutating func disconnect(_ connection: ObjectIdentifier) {
        guard self.connection == connection else { return }
        self.connection = nil
        confirmed = false
    }

    mutating func stop(_ connection: ObjectIdentifier) {
        guard self.connection == connection else { return }
        if confirmed, let snapshot = lastConfirmed {
            retiredSessions.insert(snapshot.sessionID)
        }
        lastConfirmed = nil
        disconnect(connection)
    }
}
