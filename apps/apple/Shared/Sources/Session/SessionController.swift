import Foundation
import Observation
import WaterKit

#if os(iOS)
    import UIKit
#endif

/// Starts sessions on either device: through the sport's countdown when it has one, then
/// the recorder. One shared instance, so the UI and App Intents (Shortcuts, the Action
/// button) drive the same session.
@MainActor
@Observable
final class SessionController {
    static let shared = SessionController()

    let recorder = SessionRecorder()
    /// The countdown in progress, before recording starts.
    private(set) var countdown: Countdown? {
        didSet {
            #if os(iOS)
                // A locked iPhone suspends the app, which would delay the countdown's
                // buzzes and the start, so the screen stays on until recording starts.
                UIApplication.shared.isIdleTimerDisabled = countdown != nil
            #endif
        }
    }
    /// The sport of the session being recorded or counted down to, or last recorded.
    private(set) var sport: Sport?
    /// Called with the sport, its final metrics and the folder after a recording stops.
    var onFinish: ((Sport, LiveMetrics?, URL) -> Void)?

    struct Countdown: Equatable {
        /// Tells this countdown from a later one for the same sport.
        var id = UUID()
        var sport: Sport
        var timer: StartCountdown
        /// Rounding to the minute matters at race starts (sailing).
        var canSync: Bool
    }

    private var ticker: Task<Void, Never>?

    private init() {
        recorder.onFinish = { [weak self] folder in
            guard let self, let sport = self.sport else { return }
            let metrics = self.recorder.metrics
            if let metrics {
                SettingsStore.shared.recordSession(sport, distance: metrics.distance, date: Date())
            }
            self.onFinish?(sport, metrics, folder)
        }
    }

    private var isBusyLocally: Bool { countdown != nil || recorder.state != .idle }

    #if os(iOS)
        var watchWorkout: WorkoutMirrorSnapshot? {
            guard !isBusyLocally else { return nil }
            return WatchWorkoutMirror.shared.connectedSnapshot
        }
    #endif

    var isBusy: Bool {
        #if os(iOS)
            isBusyLocally || WatchWorkoutMirror.shared.isAttached
        #else
            isBusyLocally
        #endif
    }

    /// Starts `sport`, through its countdown if it has one. Ignored while busy.
    /// `fromActionButton`: the workout session runs from the press, even during the
    /// countdown, as Apple requires of the Action button's start intent.
    func begin(_ sport: Sport, fromActionButton: Bool = false) {
        guard !isBusy else { return }
        self.sport = sport
        SettingsStore.shared.markUsed(sport)
        let settings = SettingsStore.shared[sport]
        guard var seconds = settings.countdownSeconds else {
            startRecording(sport)
            return
        }
        #if DEBUG
            // UI tests shorten the countdown: `-demoCountdownSeconds 5` with -demoSession.
            if DemoFeed.isEnabled,
                let override = UserDefaults.standard.object(forKey: "demoCountdownSeconds") as? String,
                let value = Double(override)
            {
                seconds = value
            }
        #endif
        let countdownID = UUID()
        countdown = Countdown(
            id: countdownID, sport: sport, timer: StartCountdown(duration: seconds, startingAt: Self.now), canSync: sport == .sailing)
        Haptics.play(.countdownStarted)
        if sport == .sailing {
            // The start line needs positions before recording starts.
            StartLineController.shared.countdownBegan { [weak self] in
                self?.countdown?.timer.remaining(at: Self.now) ?? 0
            }
        }
        runTicker()
        // On the watch, a prepared workout session keeps the app running with the wrist
        // down, so the buzzes and the start stay on time.
        Task { [weak self] in
            guard let self,
                let prepareID = await self.recorder.prepare(sport: sport, startWorkout: fromActionButton)
            else { return }
            // Cancelled before the session was ready: don't leave it running. Only this
            // preparation is ended; a newer countdown's is left alone.
            if self.countdown?.id != countdownID { self.recorder.cancelPrepared(prepareID) }
        }
    }

    /// Rounds the countdown to the nearest minute (the start signal).
    func sync() {
        guard var countdown else { return }
        countdown.timer.sync(at: Self.now)
        self.countdown = countdown
        Haptics.play(.sync)
        if countdown.timer.isFinished(at: Self.now) { finishCountdown(atGun: true) }
    }

    /// Skips the rest of the countdown and starts recording now.
    func startNow() {
        guard countdown != nil else { return }
        finishCountdown(atGun: false)
    }

    func cancelCountdown() {
        ticker?.cancel()
        ticker = nil
        if countdown?.sport == .sailing { StartLineController.shared.countdownEnded(gunDeadline: nil) }
        countdown = nil
        recorder.cancelPrepared()
    }

    func lap() {
        guard recorder.isRecording else { return }
        recorder.lap()
        Haptics.play(.lap)
    }

    /// Marks man-overboard (PLAN §5) at any time: during a recording, a countdown, a
    /// mirrored watch session or none. The mark comes from `ManOverboard`'s latest
    /// position (a session's fixes, or its own location updates); with none yet, it
    /// marks the first fix to arrive. The `mob` event goes into the local recording only
    /// when there is one.
    @discardableResult
    func markManOverboard() -> ManOverboard.MarkResult {
        let result = ManOverboard.shared.press()
        if recorder.isRecording { recorder.recordManOverboard(result) }
        Haptics.play(.manOverboard)
        return result
    }

    /// One press of the Action button after the one that started the session: works the
    /// countdown, or runs the sport's chosen action while recording (`ActionButtonPress`).
    @discardableResult
    func actionButtonPressed() -> ActionButtonPress {
        let recordingSport: Sport? =
            if case .recording(_, _, let sport) = recorder.state { sport } else { nil }
        let press = ActionButtonPress.resolve(
            countingDown: countdown != nil, canSync: countdown?.canSync ?? false,
            isRecording: recorder.isRecording,
            action: UserSettings.settings(for: recordingSport ?? sport ?? .sailing).actionButton)
        switch press {
        case .syncCountdown: sync()
        case .startNow: startNow()
        case .lap: lap()
        case .mark:
            recorder.mark()
            Haptics.play(.mark)
        case .manOverboard: markManOverboard()
        case .ignore: break
        }
        return press
    }

    /// Monotonic seconds, so a clock change during the countdown cannot move the start.
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func runTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var previous = Self.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let countdown = self.countdown else { return }
                let now = Self.now
                if let cue = countdown.timer.cue(from: previous, to: now) {
                    switch cue {
                    case .minute: Haptics.play(.countdownMinute)
                    case .second: Haptics.play(.countdownSecond)
                    case .start: break  // played by finishCountdown
                    }
                }
                previous = now
                if countdown.timer.isFinished(at: now) {
                    self.finishCountdown(atGun: true)
                    return
                }
            }
        }
    }

    /// `atGun`: the countdown reached zero (by itself or a sync), rather than Start now.
    private func finishCountdown(atGun: Bool) {
        guard let countdown else { return }
        #if os(iOS)
            if WatchWorkoutMirror.shared.isAttached {
                cancelCountdown()
                return
            }
        #endif
        ticker?.cancel()
        ticker = nil
        if countdown.sport == .sailing {
            // The gun is the countdown's deadline (moved by a sync), not when this runs.
            StartLineController.shared.countdownEnded(gunDeadline: atGun ? countdown.timer.endsAt : nil)
        }
        self.countdown = nil
        Haptics.play(.recordingStarted)
        startRecording(countdown.sport)
    }

    private func startRecording(_ sport: Sport) {
        recorder.start(sport: sport)
    }
}
