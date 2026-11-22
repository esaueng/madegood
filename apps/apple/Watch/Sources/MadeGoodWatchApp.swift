import SwiftUI

@main
struct MadeGoodWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserSettings.resetIfRequested()
        UserSettings.migrate()
        // Activating also re-sends recordings the phone has not received yet. Runs for
        // background launches too, before any background task below.
        RecordingTransfer.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .onChange(of: scenePhase) { _, phase in
                    // Leaving with recordings still to send, or back after a request failed:
                    // make sure a wake is asked for.
                    if phase != .inactive { RecordingTransfer.shared.scheduleRefreshIfPending() }
                }
                // On screen (also with the wrist lowered, still the frontmost app), recordings
                // go by message while the iPhone is reachable; in the background, as files.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    RecordingTransfer.shared.setForeground(phase != .background)
                }
        }
        // The phone's acknowledgements wake a suspended app; each one queues the next parts
        // of the recording. The task ends once everything delivered has been handled.
        .backgroundTask(.watchConnectivity) {
            await RecordingTransfer.shared.finishBackgroundDelivery()
        }
        // Asked for while recordings wait (`TransferPolicy.nextRefresh`): retries failed
        // and stuck transfers when no acknowledgement wakes the app.
        .backgroundTask(.appRefresh(TransferPolicy.refreshIdentifier)) {
            await RecordingTransfer.shared.resumeFromRefresh()
        }
    }
}
