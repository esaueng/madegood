import SwiftUI

@main
struct MadeGoodApp: App {
    init() {
        UserSettings.resetIfRequested()
        UserSettings.migrate()
        // Receive recordings from the watch, including ones sent while the app was closed.
        RecordingTransfer.shared.activate()
        DemoHistory.seedIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
