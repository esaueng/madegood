import SwiftUI

@main
struct MadeGoodWatchApp: App {
    init() {
        UserSettings.resetIfRequested()
        UserSettings.migrate()
        // Activating also re-sends recordings the phone has not received yet.
        RecordingTransfer.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}
