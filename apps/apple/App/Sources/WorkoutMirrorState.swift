import Foundation

/// Tracks the HealthKit connection separately from the watch's recording UUID.
struct WorkoutMirrorState {
    private var connection: ObjectIdentifier?
    private var confirmed = false
    private var retiredSessions: Set<UUID> = []
    private(set) var lastConfirmed: WorkoutMirrorSnapshot?

    var connectedSnapshot: WorkoutMirrorSnapshot? { confirmed ? lastConfirmed : nil }

    mutating func connect(_ connection: ObjectIdentifier) {
        guard self.connection != connection else { return }
        self.connection = connection
        confirmed = false
    }

    mutating func receive(_ snapshot: WorkoutMirrorSnapshot, from connection: ObjectIdentifier) {
        guard self.connection == connection, snapshot.version == WorkoutMirrorSnapshot.currentVersion,
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
    }

    mutating func disconnect(_ connection: ObjectIdentifier) {
        guard self.connection == connection else { return }
        self.connection = nil
        confirmed = false
    }

    mutating func stop(_ connection: ObjectIdentifier) {
        guard self.connection == connection else { return }
        if let snapshot = connectedSnapshot {
            retiredSessions.insert(snapshot.sessionID)
            lastConfirmed = nil
        }
        disconnect(connection)
    }
}
