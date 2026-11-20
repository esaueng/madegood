import SwiftUI

@main
struct MadeGoodApp: App {
    @UIApplicationDelegateAdaptor(VoyageSyncAppDelegate.self) private var voyageDelegate
    @Environment(\.scenePhase) private var scenePhase
    #if MADEGOOD_VOYAGES
        private let voyageSync = DemoOffWater.storage == nil ? PrivateVoyageSync.shared : nil
    #endif
    private let sessionSync = DemoOffWater.storage == nil ? SessionSync.shared : nil
    @State private var demoLibrary = SessionLibrary()
    private let demoSeedFailed: Bool

    init() {
        // Share sheets from an earlier run are gone; so is any need for their files.
        ExportFiles.removeAll()
        #if DEBUG && MADEGOOD_VOYAGES
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
        _ = AnchorWatch.shared
        // Staging copies of an interrupted transfer are never part of a recording.
        RecordingStore.removeStaleStagingFiles()
        // Prepared copies for sharing of recordings deleted since (or by an older build).
        Task.detached(priority: .utility) {
            ZipExport.prunePrepared(keeping: Set(RecordingStore.list().map(\.folder.lastPathComponent)))
        }
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
                        #if MADEGOOD_VOYAGES
                            .environment(voyageSync)
                            .task(id: voyageSync?.account.binding) { await voyageSync?.accountDidChange() }
                        #endif
                        .environment(sessionSync)
                        .task(id: sessionSync?.account.binding) { await sessionSync?.accountDidChange() }
                        .onChange(of: scenePhase) { _, phase in
                            if phase == .active {
                                AnchorWatch.shared.becameActive()
                                #if MADEGOOD_VOYAGES
                                    voyageSync?.kick()
                                #endif
                                sessionSync?.kick()
                            } else {
                                AnchorWatch.shared.becameInactive()
                            }
                        }
                }
            }
            .modifier(FollowsAppearance())
        }
    }
}
