import SwiftUI

@main
struct MadeGoodApp: App {
    init() {
        // Receive recordings from the watch, including ones sent while the app was closed.
        RecordingTransfer.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
