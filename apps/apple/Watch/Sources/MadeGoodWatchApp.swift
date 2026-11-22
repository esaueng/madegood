import SwiftUI

@main
struct MadeGoodWatchApp: App {
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
