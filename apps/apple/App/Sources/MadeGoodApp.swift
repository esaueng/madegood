import SwiftUI

@main
struct MadeGoodApp: App {
    init() {
        // HealthKit can launch the phone in the background to deliver a mirror.
        _ = WatchWorkoutMirror.shared
        UserSettings.resetIfRequested()
        UserSettings.migrate()
        // Receive recordings from the watch, including ones sent while the app was closed.
        RecordingTransfer.shared.activate()
        DemoHistory.seedIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(FollowsAppearance())
        }
    }
}

