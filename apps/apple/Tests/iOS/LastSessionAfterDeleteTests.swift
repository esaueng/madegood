import WaterKit
import XCTest

@testable import MadeGood

/// Simulator QA of #186: after deleting the newest sailing session, the start screen's card
/// still showed it, because the saved last session outlived the recording.
@MainActor
final class LastSessionAfterDeleteTests: XCTestCase {
    private let start = 946_684_800.0
    private var root: URL!
    private var saved: [Sport: UserSettings.LastSession?] = [:]
    /// Recordings this test made; a delete moves them to Recently Deleted.
    private var folderNames: Set<String> = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LastSessionAfterDelete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sport in [Sport.sailing, .kayak] { saved[sport] = UserSettings.lastSession(sport) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        let library = SessionLibrary()
        library.reload()
        for item in library.deleted where folderNames.contains(item.entry.folderName) {
            try? library.deletePermanently(item)
        }
        for (sport, last) in saved {
            if let last {
                SettingsStore.shared.recordSession(sport, distance: last.distance, date: last.date)
            } else {
                SettingsStore.shared.forgetLastSession(sport)
            }
        }
    }

    /// A finished recording on disk, as History lists it.
    private func recording(_ sport: Sport, startedAt offset: Double, minutes: Double = 60) throws
        -> SessionLibrary.Item
    {
        let begin = start + offset
        let meta = RawFormat.Meta(
            sessionId: UUID(), sport: sport, startedAt: begin, endedAt: begin + minutes * 60,
            device: .init(kind: "phone", model: "iPhone0,0", os: "iOS 26.0"), app: .init(version: "0", build: "0"))
        let folder = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folderNames.insert(folder.lastPathComponent)
        try Data(count: 10).write(to: folder.appendingPathComponent("gps.ndjson.gz"))
        return SessionLibrary.Item(
            entry: RecordingStore.Entry(folder: folder, meta: meta, revision: RawSessionReader.revision(of: folder)))
    }

    /// Saved the way the recorder saves it: when the recording finishes.
    private func saveLastSession(of item: SessionLibrary.Item, distance: Double) {
        let ended = Date(timeIntervalSince1970: item.entry.meta!.endedAt! + 1)
        SettingsStore.shared.recordSession(item.entry.meta!.sport, distance: distance, date: ended)
    }

    func testDeletingTheSavedSessionForgetsIt() throws {
        let sailing = try recording(.sailing, startedAt: 0)
        let kayak = try recording(.kayak, startedAt: 0)
        saveLastSession(of: sailing, distance: 20)
        saveLastSession(of: kayak, distance: 30)

        try SessionLibrary().delete(sailing)

        XCTAssertNil(SettingsStore.shared.lastSessions[.sailing])
        XCTAssertNil(UserSettings.lastSession(.sailing))
        XCTAssertEqual(SettingsStore.shared.lastSessions[.kayak]?.distance, 30, "another sport's was forgotten")
    }

    /// Review of this fix: a newer watch outing is the newest recording, but the saved session
    /// is the iPhone's earlier one, which survives.
    func testDeletingAnotherSessionKeepsTheSavedOne() throws {
        let phone = try recording(.sailing, startedAt: 0)
        let watch = try recording(.sailing, startedAt: 7_200)
        saveLastSession(of: phone, distance: 20)

        try SessionLibrary().delete(watch)

        XCTAssertEqual(SettingsStore.shared.lastSessions[.sailing]?.distance, 20)
    }

    /// Re-check of this fix: a watch outing ends at 12:00 and the iPhone's next one is saved at
    /// 12:01:30, inside the watch recording's tolerance. The save is the iPhone outing's.
    func testBackToBackOutingsMatchOnlyTheLaterOne() throws {
        let watch = try recording(.sailing, startedAt: 0, minutes: 60)
        let phone = try recording(.sailing, startedAt: 3_630, minutes: 1)
        let saved = UserSettings.LastSession(
            distance: 1, date: Date(timeIntervalSince1970: phone.entry.meta!.endedAt! + 2))
        let entries = [phone.entry, watch.entry]
        XCTAssertFalse(SessionLibrary.lastSession(saved, describes: watch.entry, among: entries))
        XCTAssertTrue(SessionLibrary.lastSession(saved, describes: phone.entry, among: entries))
    }

    func testOnlyASessionSavedWithinTheRecordingMatches() throws {
        let item = try recording(.sailing, startedAt: 0, minutes: 30)
        let ended = item.entry.meta!.endedAt!
        func saved(at time: Double) -> UserSettings.LastSession {
            UserSettings.LastSession(distance: 1, date: Date(timeIntervalSince1970: time))
        }
        XCTAssertTrue(SessionLibrary.lastSession(saved(at: ended + 1), describes: item.entry))
        XCTAssertFalse(SessionLibrary.lastSession(saved(at: start - 1), describes: item.entry))
        XCTAssertFalse(
            SessionLibrary.lastSession(
                saved(at: ended + SessionLibrary.lastSessionSaveTolerance + 1), describes: item.entry))
    }
}
