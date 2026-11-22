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

    private var motion: [TransferParts.Part] { TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: partSize) }

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
            local: local, holds: holds, inFlight: [.init(motion[2])], partSize: partSize)
        // gps differs in size on the phone, so it goes. The phone holds meta.json, and the
        // acknowledgements of what goes now say what else it holds, so meta.json stays.
        XCTAssertEqual(names(units), ["gps.ndjson.gz", "motion.ndjson.gz#1"])
        // Without meta.json on the phone, it goes last.
        var noMeta = holds
        noMeta.files["meta.json"] = nil
        XCTAssertEqual(
            names(RecordingTransfer.units(local: local, holds: noMeta, inFlight: [], partSize: partSize)),
            ["motion.ndjson.gz#2", "gps.ndjson.gz", "motion.ndjson.gz#1", "meta.json"])
    }

    /// meta.json went whenever it was not in flight, and each acknowledgement of it that did
    /// not complete the recording sent the watch round again: while the last parts were still
    /// in flight, meta.json went back and forth between the devices until they arrived.
    func testMetaIsNotSentAgainWhileThePhoneHoldsItAndPartsAreInFlight() {
        let holds = RecordingTransfer.PhoneHolds(
            files: ["events.ndjson.gz": 3, "gps.ndjson.gz": 8, "meta.json": 4],
            parts: ["motion.ndjson.gz|25|10": [0, 1]])
        let inFlight: Set<RecordingTransfer.UnitKey> = [.init(motion[2])]
        XCTAssertEqual(
            RecordingTransfer.units(local: local, holds: holds, inFlight: inFlight, partSize: partSize), [])
        // Its first time, meta.json goes even while parts are in flight.
        var noMeta = holds
        noMeta.files["meta.json"] = nil
        XCTAssertEqual(
            names(RecordingTransfer.units(local: local, holds: noMeta, inFlight: inFlight, partSize: partSize)),
            ["meta.json"])
        // A stale list that claims everything: meta.json goes alone, and its acknowledgement
        // says what the phone really holds.
        let everything = RecordingTransfer.PhoneHolds(files: local)
        XCTAssertEqual(
            names(RecordingTransfer.units(local: local, holds: everything, inFlight: [], partSize: partSize)),
            ["meta.json"])
        // Parts handed over and waiting for their acknowledgements also hold meta.json back
        // once the phone has it: those acknowledgements say what else it holds.
        let handedOver: Set<RecordingTransfer.UnitKey> = [.init(motion[2])]
        XCTAssertEqual(
            RecordingTransfer.units(
                local: local, holds: holds, inFlight: [], handedOver: handedOver, partSize: partSize),
            [])
        // ...but not before the phone has it: meta.json follows them.
        XCTAssertEqual(
            names(
                RecordingTransfer.units(
                    local: local, holds: noMeta, inFlight: [], handedOver: handedOver, partSize: partSize)),
            ["meta.json"])
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
            inFlight: [.init(motion[2]), .init(motion[0])],
            partSize: partSize, window: 2)
        XCTAssertEqual(names(full), ["events.ndjson.gz", "gps.ndjson.gz"])
        // The last part fits: meta.json follows it.
        let last = RecordingTransfer.units(
            local: local, holds: nil,
            inFlight: [.init(motion[2]), .init(motion[0])],
            partSize: partSize, window: 3)
        XCTAssertEqual(names(last), ["events.ndjson.gz", "gps.ndjson.gz", "motion.ndjson.gz#1", "meta.json"])
    }

    /// Re-check of #167, finding 1: a part that just finished but whose acknowledgement has
    /// not come in is not queued again, or the window would cycle through the same parts
    /// and meta.json would never go.
    func testAPartJustHandedOverIsNotSentAgainAndMetaStillGoes() {
        let units = RecordingTransfer.units(
            local: local, holds: nil, inFlight: [], handedOver: [.init(motion[0]), .init(motion[1]), .init(motion[2])],
            partSize: partSize, window: 1)
        XCTAssertEqual(names(units), ["events.ndjson.gz", "gps.ndjson.gz", "meta.json"])
    }

    /// Re-check finding 2: a part of another layout in flight doesn't block this layout's.
    func testAPartOfAnotherLayoutInFlightDoesNotBlockThisOne() {
        let old = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 20)[0]
        let units = RecordingTransfer.units(
            local: local, holds: nil, inFlight: [.init(old)], partSize: partSize, window: 10)
        XCTAssertTrue(names(units).contains("motion.ndjson.gz#0"))
    }

    /// Review of #170, finding 4: a join on the phone without background time, or whose time
    /// runs out partway, must leave no staged or half-placed file, keep its parts, and be
    /// done in full later.
    func testAJoinWithoutTimeOrCutShortKeepsItsPartsAndIsDoneLater() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        try bytes(25).write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        for part in motion {
            let inbox = root.appendingPathComponent("inbox-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: try TransferParts.slice(part, in: watch), to: inbox)
            _ = try TransferParts.store(inbox, as: part, in: phone)
        }
        let transfer = RecordingTransfer(syncsSettings: false)
        let sessionId = UUID().uuidString.lowercased()
        func contents() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: phone.path)) ?? []).sorted()
        }

        // No time: not started.
        XCTAssertEqual(transfer.joinCompleteFiles(in: phone, sessionId: sessionId) { false }, [])
        XCTAssertEqual(contents(), [".parts"])
        XCTAssertEqual(TransferParts.held(in: phone), ["motion.ndjson.gz|25|10": [0, 1, 2]])

        // Time runs out after the first part.
        var asked = 0
        XCTAssertEqual(
            transfer.joinCompleteFiles(in: phone, sessionId: sessionId) {
                asked += 1
                return asked <= 2
            }, [])
        XCTAssertEqual(contents(), [".parts"])
        XCTAssertEqual(TransferParts.held(in: phone), ["motion.ndjson.gz|25|10": [0, 1, 2]])

        // With time, it is joined and the parts go.
        XCTAssertEqual(transfer.joinCompleteFiles(in: phone, sessionId: sessionId) { true }, ["motion.ndjson.gz"])
        XCTAssertEqual(contents(), ["motion.ndjson.gz"])
        XCTAssertEqual(try Data(contentsOf: phone.appendingPathComponent("motion.ndjson.gz")), bytes(25))
    }

    func testAJoinStopsBetweenPartsWhenAsked() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        try bytes(25).write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        for part in motion {
            let inbox = root.appendingPathComponent("inbox-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: try TransferParts.slice(part, in: watch), to: inbox)
            _ = try TransferParts.store(inbox, as: part, in: phone)
        }
        var asked = 0
        XCTAssertThrowsError(
            try TransferParts.join(motion[0], in: phone, stagingPrefix: ".incoming-") {
                asked += 1
                return asked < 3
            }
        ) { XCTAssertEqual($0 as? TransferParts.PartError, .interrupted) }
        let left = try FileManager.default.contentsOfDirectory(atPath: phone.path)
        XCTAssertFalse(left.contains { $0.hasPrefix(".incoming-") })
        XCTAssertEqual(TransferParts.complete(in: phone).count, 1)

        // Re-check of #170, finding 2: time running out during the last part's write. Every
        // part is written, but the joined file is not handed over for placing.
        asked = 0
        XCTAssertThrowsError(
            try TransferParts.join(motion[0], in: phone, stagingPrefix: ".incoming-") {
                asked += 1
                return asked <= motion.count
            }
        ) { XCTAssertEqual($0 as? TransferParts.PartError, .interrupted) }
        XCTAssertEqual(asked, motion.count + 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: phone.path), [".parts"])
        XCTAssertEqual(TransferParts.complete(in: phone).count, 1)
    }

    /// The phone held every part but had no time to join them, so its acknowledgement
    /// listed the parts, not the file. Those parts, handed over minutes earlier, must not hold
    /// meta.json back: meta.json is what brings the phone back to the join.
    func testPartsThePhoneListsDoNotHoldMetaBack() {
        let handedOver = Set(motion.map(RecordingTransfer.UnitKey.init))
        let allParts = RecordingTransfer.PhoneHolds(
            files: ["events.ndjson.gz": 3, "gps.ndjson.gz": 8, "meta.json": 4],
            parts: ["motion.ndjson.gz|25|10": [0, 1, 2]])
        XCTAssertEqual(
            names(
                RecordingTransfer.units(
                    local: local, holds: allParts, inFlight: [], handedOver: handedOver, partSize: partSize)),
            ["meta.json"])
        // While one of them is not listed yet, its acknowledgement is still on the way.
        var twoParts = allParts
        twoParts.parts["motion.ndjson.gz|25|10"] = [0, 1]
        XCTAssertEqual(
            RecordingTransfer.units(
                local: local, holds: twoParts, inFlight: [], handedOver: handedOver, partSize: partSize),
            [])
    }

    /// Re-check of #170, finding 1: a send passed the retry check; WatchConnectivity then
    /// dropped a failed part from its outstanding list, the send took its snapshot without
    /// it, and queued it again before the failure's callback set the retry.
    func testAPartWhoseFailureIsBeingHandledIsNotQueuedAgain() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = RecordingTransfer.Submitted()
        var retry = RecordingTransfer.Retry()
        let failing = RecordingTransfer.UnitKey(motion[1])
        ledger.add(id: "motion#1", key: failing)

        // Gone from the outstanding list, callback not handled yet: still in flight.
        let snapshot = ledger.inFlight(outstanding: [], now: now)
        XCTAssertTrue(snapshot.contains(failing))
        let units = RecordingTransfer.units(local: local, holds: nil, inFlight: snapshot, partSize: partSize)
        XCTAssertFalse(names(units).contains("motion.ndjson.gz#1"))

        // The callback sets the retry, then leaves the ledger. A snapshot taken after that
        // misses the part, but the check after it sees the retry.
        XCTAssertNotNil(retry.failed(now: now))
        ledger.finished(id: "motion#1")
        XCTAssertFalse(ledger.inFlight(outstanding: [], now: now).contains(failing))
        XCTAssertFalse(retry.allowsSend(now: now.addingTimeInterval(1), userAsked: false))
    }

    func testATransferLostWithoutACallbackIsNotCountedForever() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = RecordingTransfer.Submitted()
        let lost = RecordingTransfer.UnitKey(motion[0])
        let moving = RecordingTransfer.UnitKey(motion[2])
        ledger.add(id: "lost", key: lost)
        ledger.add(id: "moving", key: moving)
        XCTAssertEqual(ledger.inFlight(outstanding: ["moving"], now: now), [lost, moving])
        let later = now.addingTimeInterval(RecordingTransfer.Submitted.callbackGrace)
        // Outstanding ones stay however long; one missing for the grace period goes.
        XCTAssertEqual(ledger.inFlight(outstanding: ["moving"], now: later), [moving])
    }

    func testEachTransferHasItsOwnID() {
        func id(_ part: TransferParts.Part?, file: String = "motion.ndjson.gz", at: Double = 1) -> String? {
            var metadata: [String: Any] = ["file": file, "queuedAt": at]
            if let part { metadata.merge(TransferParts.metadata(for: part)) { $1 } }
            return RecordingTransfer.transferID(metadata: metadata)
        }
        let other = TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 20)[0]
        let ids = [id(motion[0]), id(motion[1]), id(other), id(motion[0], at: 2), id(nil), id(nil, file: "meta.json")]
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, ids.count)
        XCTAssertEqual(id(motion[0]), id(motion[0]))
        XCTAssertNil(RecordingTransfer.transferID(metadata: nil))
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

    /// A transfer lost when the watch restarted, or cancelled, left its slice behind: one
    /// slice per part, for as long as the recording stayed on the watch.
    func testSlicesNoTransferUsesAreFoundForRemoval() throws {
        let watch = try folder("watch")
        try bytes(25).write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        let slices = try TransferParts.plan(file: "motion.ndjson.gz", size: 25, partSize: 10)
            .map { try TransferParts.slice($0, in: watch) }
        // Something else in .parts that is not a file is left alone.
        try FileManager.default.createDirectory(
            at: watch.appendingPathComponent(".parts/motion.ndjson.gz", isDirectory: true),
            withIntermediateDirectories: true)
        let stale = TransferParts.staleSlices(in: watch, inUse: [slices[1].lastPathComponent])
        XCTAssertEqual(stale.map(\.lastPathComponent), [slices[0], slices[2]].map(\.lastPathComponent))
        XCTAssertEqual(TransferParts.staleSlices(in: try folder("empty"), inUse: []), [])
        // The recording's own files are never among them.
        XCTAssertFalse(stale.contains { $0.lastPathComponent == "motion.ndjson.gz" })
    }

    func testAWholeFileInFlightCoversItsParts() {
        // A transfer queued whole by an earlier build keeps going; no parts are added.
        let units = RecordingTransfer.units(
            local: local, holds: nil, inFlight: [.whole("motion.ndjson.gz")], partSize: partSize)
        XCTAssertFalse(units.contains { $0.file == "motion.ndjson.gz" })
    }

    func testThePhonesPartsAreReadFromAnAcknowledgement() {
        let ack: [String: Any] = ["parts": ["motion.ndjson.gz": [NSNumber(value: 0), NSNumber(value: 3)]]]
        XCTAssertEqual(RecordingTransfer.phoneParts(fromAcknowledgement: ack), ["motion.ndjson.gz": [0, 3]])
        XCTAssertEqual(RecordingTransfer.phoneParts(fromAcknowledgement: ["files": [:] as [String: Any]]), [:])
    }
}
