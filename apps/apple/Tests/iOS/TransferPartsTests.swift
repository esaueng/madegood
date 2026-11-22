import WaterKit
import XCTest

@testable import MadeGood

/// Large files go from the watch in parts: an interruption costs one part, not the file.
final class TransferPartsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    func testOnlyFilesLargerThanAPartGoInParts() {
        XCTAssertEqual(TransferParts.plan(file: "gps.ndjson.gz", size: 10, partSize: 10), [])
        let parts = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)
        XCTAssertEqual(parts.map(\.index), [0, 1, 2])
        XCTAssertEqual(parts.map(\.offset), [0, 10, 20])
        XCTAssertEqual(parts.map(\.length), [10, 10, 5])
        // The device case: a 35,236,161-byte motion stream in 1 MiB parts.
        XCTAssertEqual(TransferParts.plan(file: "motion.ndjson.gz", size: 35_236_161).count, 34)
    }

    func testAPartRoundTripsThroughTransferMetadata() throws {
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)[1]
        XCTAssertEqual(try TransferParts.part(file: part.file, metadata: TransferParts.metadata(for: part)), part)
        XCTAssertNil(try TransferParts.part(file: "gps.ndjson.gz", metadata: ["sessionId": "x"]))
        // Delivered as a property list: numbers come back as NSNumber.
        let plist = TransferParts.metadata(for: part).mapValues { NSNumber(value: ($0 as! NSNumber).int64Value) }
        XCTAssertEqual(try TransferParts.part(file: part.file, metadata: plist), part)
    }

    func testThePhoneRefusesPartMetadataThatCannotBeRight() {
        let bad: [[String: Any]] = [
            ["part": 3, "parts": 3, "total": 25, "partSize": 10],  // index out of range
            ["part": 0, "parts": 2, "total": 25, "partSize": 10],  // wrong count
            ["part": 0, "parts": 1, "total": 5, "partSize": 10],  // too small to be in parts
            ["part": 0, "parts": 1, "total": 1 << 30, "partSize": 1 << 30],  // absurd part size
            ["part": "0", "parts": 3, "total": 25, "partSize": 10],
        ]
        for metadata in bad {
            XCTAssertThrowsError(try TransferParts.part(file: "motion.ndjson.gz", metadata: metadata), "\(metadata)")
        }
    }

    /// The watch slices the file, the phone stores the parts in any order (some twice), and
    /// joins them into exactly the original file.
    func testPartsSlicedOnTheWatchJoinIntoTheOriginalOnThePhone() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        let original = bytes(25)
        try original.write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        let parts = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)

        func deliver(_ part: TransferParts.Part) throws -> TransferParts.Stored {
            // WatchConnectivity hands the phone its own copy, which it may move away.
            let slice = try TransferParts.slice(part, in: watch)
            let inbox = root.appendingPathComponent("inbox-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: slice, to: inbox)
            return try TransferParts.store(inbox, as: part, in: phone)
        }

        XCTAssertEqual(try deliver(parts[2]), .stored)
        XCTAssertNil(try TransferParts.join(parts[2], in: phone, stagingPrefix: ".incoming-"))
        XCTAssertEqual(try deliver(parts[0]), .stored)
        XCTAssertEqual(try deliver(parts[0]), .alreadyHad)
        XCTAssertEqual(TransferParts.held(in: phone), ["motion.ndjson.gz|25|10": [0, 2]])
        XCTAssertNil(try TransferParts.join(parts[0], in: phone, stagingPrefix: ".incoming-"))

        XCTAssertEqual(try deliver(parts[1]), .stored)
        let staged = try XCTUnwrap(try TransferParts.join(parts[1], in: phone, stagingPrefix: ".incoming-"))
        XCTAssertEqual(try Data(contentsOf: staged), original)
        XCTAssertTrue(staged.lastPathComponent.hasPrefix(".incoming-"))

        TransferParts.removeParts(file: "motion.ndjson.gz", in: phone)
        XCTAssertEqual(TransferParts.held(in: phone), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent(".parts").path))
        // Parts are never recording files: listings and the delete decision ignore them.
        XCTAssertFalse(RecordingStore.isRecordingFileName(TransferParts.folderName))
    }

    func testThePhoneRefusesAPartOfTheWrongSize() throws {
        let phone = try folder("phone")
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)[0]
        let inbox = root.appendingPathComponent("inbox")
        try bytes(9).write(to: inbox)
        XCTAssertThrowsError(try TransferParts.store(inbox, as: part, in: phone))
        XCTAssertEqual(TransferParts.held(in: phone), [:])
    }

    // MARK: What the watch sends

    private let partSize: Int64 = 10
    private let local: [String: Int64] = [
        "meta.json": 4, "events.ndjson.gz": 3, "gps.ndjson.gz": 8, "motion.ndjson.gz": 25,
    ]

    private func names(_ units: [RecordingTransfer.Unit]) -> [String] {
        units.map { unit in unit.part.map { "\(unit.file)#\($0.index)" } ?? unit.file }
    }

    /// Seen on device: the 35 MB motion stream went second and held up every other file,
    /// meta.json included. Small files go first, large ones in parts, meta.json last.
    func testSmallFilesGoFirstLargeOnesInPartsAndMetaLast() {
        let units = RecordingTransfer.units(local: local, holds: nil, inFlight: [], partSize: partSize)
        XCTAssertEqual(
            names(units),
            [
                "events.ndjson.gz", "motion.ndjson.gz#2", "gps.ndjson.gz", "motion.ndjson.gz#0", "motion.ndjson.gz#1",
                "meta.json",
            ])
    }

    func testTheWatchSendsOnlyWhatThePhoneLacksAndIsNotInFlight() {
        let holds = RecordingTransfer.PhoneHolds(
            files: ["events.ndjson.gz": 3, "gps.ndjson.gz": 7, "meta.json": 4],
            parts: ["motion.ndjson.gz|25|10": [0]])
        let units = RecordingTransfer.units(
            local: local, holds: holds, inFlight: [.init(file: "motion.ndjson.gz", part: 2)], partSize: partSize)
        // gps differs in size on the phone, so it goes; meta.json always goes, last.
        XCTAssertEqual(names(units), ["gps.ndjson.gz", "motion.ndjson.gz#1", "meta.json"])
    }

    /// Review of #167, finding 1: parts cut another way (a different total or part size)
    /// must never be skipped as held or joined with this layout's parts, or the phone would
    /// build a file of the right size from the wrong bytes.
    func testPartsOfAnotherLayoutAreNeverSkippedOrJoined() throws {
        let otherLayout = RecordingTransfer.PhoneHolds(parts: ["motion.ndjson.gz|25|5": [0, 1, 2, 3, 4]])
        let units = RecordingTransfer.units(local: local, holds: otherLayout, inFlight: [], partSize: partSize)
        XCTAssertEqual(units.filter { $0.file == "motion.ndjson.gz" }.count, 3)

        let watch = try folder("watch")
        let phone = try folder("phone")
        try bytes(25).write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        func deliver(_ part: TransferParts.Part) throws {
            let inbox = root.appendingPathComponent("inbox-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: try TransferParts.slice(part, in: watch), to: inbox)
            _ = try TransferParts.store(inbox, as: part, in: phone)
        }
        let fives = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 5)
        try deliver(fives[2])
        // The file is now cut in tens: the old layout's parts are dropped.
        let tens = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)
        for part in tens { try deliver(part) }
        XCTAssertEqual(TransferParts.held(in: phone), ["motion.ndjson.gz|25|10": [0, 1, 2]])
        let staged = try XCTUnwrap(try TransferParts.join(tens[0], in: phone, stagingPrefix: ".incoming-"))
        XCTAssertEqual(try Data(contentsOf: staged), bytes(25))
    }

    /// Finding 3: the app stopped after storing the last part but before joining. The parts
    /// are all held, so no further part arrives to trigger the join; the phone finds the
    /// complete layout when the next file (meta.json) arrives.
    func testACompleteSetOfPartsIsFoundWithoutANewPart() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        try bytes(25).write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        let parts = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)
        for part in parts.dropLast() {
            let inbox = root.appendingPathComponent("inbox-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: try TransferParts.slice(part, in: watch), to: inbox)
            _ = try TransferParts.store(inbox, as: part, in: phone)
        }
        XCTAssertEqual(TransferParts.complete(in: phone), [])
        let inbox = root.appendingPathComponent("inbox-last")
        try FileManager.default.copyItem(at: try TransferParts.slice(parts[2], in: watch), to: inbox)
        _ = try TransferParts.store(inbox, as: parts[2], in: phone)
        let ready = TransferParts.complete(in: phone)
        XCTAssertEqual(ready.map(\.file), ["motion.ndjson.gz"])
        let staged = try XCTUnwrap(try TransferParts.join(ready[0], in: phone, stagingPrefix: ".incoming-"))
        XCTAssertEqual(try Data(contentsOf: staged), bytes(25))
    }

    /// Finding 5: only a window of parts is queued at once (each slice is a copy on the
    /// watch), and meta.json waits until everything else is queued.
    func testOnlyAWindowOfPartsIsQueuedAndMetaWaits() {
        let first = RecordingTransfer.units(local: local, holds: nil, inFlight: [], partSize: partSize, window: 2)
        XCTAssertEqual(names(first), ["events.ndjson.gz", "motion.ndjson.gz#2", "gps.ndjson.gz", "motion.ndjson.gz#0"])
        // Two parts in flight fill the window.
        let full = RecordingTransfer.units(
            local: local, holds: nil,
            inFlight: [.init(file: "motion.ndjson.gz", part: 2), .init(file: "motion.ndjson.gz", part: 0)],
            partSize: partSize, window: 2)
        XCTAssertEqual(names(full), ["events.ndjson.gz", "gps.ndjson.gz"])
        // The last part fits: meta.json follows it.
        let last = RecordingTransfer.units(
            local: local, holds: nil,
            inFlight: [.init(file: "motion.ndjson.gz", part: 2), .init(file: "motion.ndjson.gz", part: 0)],
            partSize: partSize, window: 3)
        XCTAssertEqual(names(last), ["events.ndjson.gz", "gps.ndjson.gz", "motion.ndjson.gz#1", "meta.json"])
    }

    func testOnlyAPartsSliceIsEverRemoved() throws {
        let watch = try folder("watch")
        try bytes(25).write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        let slice = try TransferParts.slice(TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)[0], in: watch)
        TransferParts.removeSlice(at: watch.appendingPathComponent("motion.ndjson.gz"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watch.appendingPathComponent("motion.ndjson.gz").path))
        TransferParts.removeSlice(at: slice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: slice.path))
    }

    func testAWholeFileInFlightCoversItsParts() {
        // A transfer queued whole by an earlier build keeps going; no parts are added.
        let units = RecordingTransfer.units(
            local: local, holds: nil, inFlight: [.init(file: "motion.ndjson.gz", part: nil)], partSize: partSize)
        XCTAssertFalse(units.contains { $0.file == "motion.ndjson.gz" })
    }

    func testThePhonesPartsAreReadFromAnAcknowledgement() {
        let ack: [String: Any] = ["parts": ["motion.ndjson.gz": [NSNumber(value: 0), NSNumber(value: 3)]]]
        XCTAssertEqual(RecordingTransfer.phoneParts(fromAcknowledgement: ack), ["motion.ndjson.gz": [0, 3]])
        XCTAssertEqual(RecordingTransfer.phoneParts(fromAcknowledgement: ["files": [:] as [String: Any]]), [:])
    }
}
