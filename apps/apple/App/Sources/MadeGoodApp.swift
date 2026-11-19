import SwiftUI

@main
struct MadeGoodApp: App {
    @UIApplicationDelegateAdaptor(VoyageSyncAppDelegate.self) private var voyageDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let voyageSync = DemoOffWater.storage == nil ? PrivateVoyageSync.shared : nil
    private let sessionSync = DemoOffWater.storage == nil ? SessionSync.shared : nil
    @State private var demoLibrary = SessionLibrary()
    private let demoSeedFailed: Bool

    init() {
        #if DEBUG
            VoyageRecorder.forgetTestLibraryIfRequested()
        #endif
        if DemoOffWater.storage != nil {
            do {
                try DemoOffWater.seedIfRequested()
                demoSeedFailed = false
            } catch {
                demoSeedFailed = true
            }
            return
        }
        demoSeedFailed = false
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
            Group {
                if demoSeedFailed {
                    ContentUnavailableView(
                        "Can't create the synthetic recording", systemImage: "exclamationmark.triangle")
                } else if DemoOffWater.storage != nil {
                    HistoryView(library: demoLibrary)
                } else {
                    ContentView()
                        .environment(voyageSync)
                        .environment(sessionSync)
                        .task(id: voyageSync?.account.binding) { await voyageSync?.accountDidChange() }
                        .task(id: sessionSync?.account.binding) { await sessionSync?.accountDidChange() }
                        .onChange(of: scenePhase) { _, phase in
                            if phase == .active {
                                voyageSync?.kick()
                                sessionSync?.kick()
                            }
                        }
                }
            }
            .modifier(FollowsAppearance())
        }
    }
}
