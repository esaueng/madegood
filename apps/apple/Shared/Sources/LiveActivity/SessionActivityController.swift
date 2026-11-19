#if os(iOS)
    import ActivityKit
    import Foundation
    import WaterKit

    /// Starts, updates and ends the session Live Activity. Updates are throttled: the
    /// system budgets them, and the timer on the Lock Screen ticks by itself.
    @MainActor
    final class SessionActivityController {
        nonisolated static let minimumUpdateInterval: TimeInterval = 5
        /// Man-overboard guidance on the Lock Screen is stale after this long without an
        /// update, s, so a suspended or ended app never leaves an old distance showing.
        nonisolated static let manOverboardStaleAfter: TimeInterval = 10

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
                let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state))
                let activity = try Activity.request(attributes: attributes, content: content)
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
            let now = Date()
            guard Self.shouldSend(state, after: lastState, lastUpdate: lastUpdate, now: now) else { return }
            lastUpdate = now
            lastState = state
            let id = activity.id
            let staleDate = Self.staleDate(for: state)
            enqueue {
                // Look the activity up inside the task: Activity is not Sendable.
                for activity in Activity<SessionActivityAttributes>.activities where activity.id == id {
                    await activity.update(.init(state: state, staleDate: staleDate))
                }
            }
        }

        func end(_ metrics: LiveMetrics?, sport: Sport) {
            guard let activity else { return }
            self.activity = nil
            lastState = nil
            let final = Self.finalState(Self.state(metrics, sport: sport))
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
                pauseLabel: metrics.flatMap { LiveDisplay.pauseLabel($0.pauseState) }
            )
            .withManOverboard(ManOverboard.shared, display: display)
        }

        /// Pause and man-overboard changes (marked, guidance lost or back, a location
        /// problem, cleared) go out at once; otherwise at most every few seconds. Each new
        /// fix changes the state (its time), so guidance and its stale date keep moving.
        nonisolated static func shouldSend(
            _ state: SessionActivityAttributes.ContentState, after last: SessionActivityAttributes.ContentState?,
            lastUpdate: Date, now: Date
        ) -> Bool {
            guard let last else { return true }
            if state.pauseLabel != last.pauseLabel || state.manOverboardKind != last.manOverboardKind { return true }
            guard now.timeIntervalSince(lastUpdate) >= minimumUpdateInterval else { return false }
            return state != last
        }

        /// Man-overboard guidance goes stale `manOverboardStaleAfter` after the fix it was
        /// computed from was measured, not after it was sent.
        nonisolated static func staleDate(for state: SessionActivityAttributes.ContentState) -> Date? {
            guard state.manOverboardHasGuidance == true, let fixAt = state.manOverboardFixAt else { return nil }
            return fixAt.addingTimeInterval(manOverboardStaleAfter)
        }

        /// The content an ended activity keeps: no man-overboard guidance, which would
        /// otherwise stay on the Lock Screen with nothing updating it.
        nonisolated static func finalState(
            _ state: SessionActivityAttributes.ContentState
        ) -> SessionActivityAttributes.ContentState {
            var final = state
            final.manOverboard = nil
            final.manOverboardHasGuidance = nil
            final.manOverboardLocationIssue = nil
            final.manOverboardNote = nil
            final.manOverboardFixAt = nil
            return final
        }
    }

    extension SessionActivityAttributes.ContentState {
        @MainActor
        func withManOverboard(
            _ manOverboard: ManOverboard, display: LiveDisplay
        ) -> SessionActivityAttributes.ContentState {
            withManOverboard(
                isActive: manOverboard.isActive, guidance: manOverboard.guidance(),
                fixAt: manOverboard.position?.at, mark: manOverboard.mark,
                locationIssue: manOverboard.locationIssue, display: display)
        }

        /// Adds distance and true bearing back to the man-overboard target, a location
        /// problem, or a waiting message, when a mark is set or a press waits for one,
        /// with how far to trust the mark and the fix time for the stale date.
        func withManOverboard(
            isActive: Bool, guidance: ManOverboard.Guidance?, fixAt: Date?, mark: ManOverboard.Mark?,
            locationIssue: ManOverboard.LocationIssue?, display: LiveDisplay
        ) -> SessionActivityAttributes.ContentState {
            var state = SessionActivityController.finalState(self)
            guard isActive else { return state }
            if let guidance, let fixAt {
                state.manOverboard = "\(display.distance(guidance.distance)) · \(LiveDisplay.course(guidance.bearing))"
                state.manOverboardHasGuidance = true
                state.manOverboardFixAt = fixAt
            } else if let locationIssue {
                state.manOverboard = ManOverboardNotes.locationIssue(locationIssue)
                state.manOverboardHasGuidance = false
                state.manOverboardLocationIssue = true
            } else {
                state.manOverboard = mark == nil ? "Getting a position to mark" : "Waiting for GPS"
                state.manOverboardHasGuidance = false
            }
            state.manOverboardNote = mark.flatMap(ManOverboardNotes.markQuality)
            return state
        }
    }
#endif
