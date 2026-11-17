#if os(iOS)
    import ActivityKit
    import Foundation
    import WaterKit

    /// Starts, updates and ends the session Live Activity. Updates are throttled: the
    /// system budgets them, and the timer on the Lock Screen ticks by itself.
    @MainActor
    final class SessionActivityController {
        static let minimumUpdateInterval: TimeInterval = 5

        private var activity: Activity<SessionActivityAttributes>?
        private var lastUpdate = Date.distantPast
        private var lastState: SessionActivityAttributes.ContentState?
        /// Activity operations run one after another, in the order the recorder made them.
        private var queue: Task<Void, Never>?

        /// Ends activities left by an earlier run of the app (for example after iOS ended
        /// the process mid-session): a session never resumes after a relaunch.
        init() {
            enqueue { await Self.endAll(except: nil) }
        }

        func start(sport: Sport, startedAt: Date) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
            let attributes = SessionActivityAttributes(
                sportName: sport.displayName, sportIcon: sport.iconName, startedAt: startedAt)
            let state = Self.state(nil, sport: sport)
            do {
                let activity = try Activity.request(
                    attributes: attributes, content: .init(state: state, staleDate: nil))
                self.activity = activity
                lastState = state
                lastUpdate = Date()
                let id = activity.id
                enqueue { await Self.endAll(except: id) }
            } catch {
                print("SessionActivityController: could not start: \(error)")
            }
        }

        /// Called with every new snapshot, including the recorder's 1 s tick, so a state
        /// held back by the throttle (or a speed blanked when GPS goes quiet) goes out on a
        /// later call.
        func update(_ metrics: LiveMetrics?, sport: Sport) {
            guard let activity else { return }
            let state = Self.state(metrics, sport: sport)
            // Pause changes go out at once; otherwise at most every few seconds.
            let pauseChanged = state.pauseLabel != lastState?.pauseLabel
            guard state != lastState, pauseChanged || Date().timeIntervalSince(lastUpdate) >= Self.minimumUpdateInterval
            else { return }
            lastUpdate = Date()
            lastState = state
            let id = activity.id
            enqueue {
                // Look the activity up inside the task: Activity is not Sendable.
                for activity in Activity<SessionActivityAttributes>.activities where activity.id == id {
                    await activity.update(.init(state: state, staleDate: nil))
                }
            }
        }

        func end(_ metrics: LiveMetrics?, sport: Sport) {
            guard let activity else { return }
            self.activity = nil
            lastState = nil
            let final = Self.state(metrics, sport: sport)
            let id = activity.id
            enqueue {
                for activity in Activity<SessionActivityAttributes>.activities where activity.id == id {
                    await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .default)
                }
            }
        }

        private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
            let previous = queue
            queue = Task.detached {
                await previous?.value
                await operation()
            }
        }

        private nonisolated static func endAll(except keep: String?) async {
            for activity in Activity<SessionActivityAttributes>.activities where activity.id != keep {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        static func state(_ metrics: LiveMetrics?, sport: Sport) -> SessionActivityAttributes.ContentState {
            let display = UserSettings.display(for: sport)
            return SessionActivityAttributes.ContentState(
                speed: display.speed(metrics?.speed),
                speedNumber: metrics?.speed.map { String(display.speed.display($0).text.split(separator: " ")[0]) }
                    ?? "–",
                distance: display.distance(metrics?.distance ?? 0),
                movingTime: Formatting.elapsed(metrics?.movingTime ?? 0),
                pauseLabel: metrics.flatMap { LiveDisplay.pauseLabel($0.pauseState) })
        }
    }
#endif
