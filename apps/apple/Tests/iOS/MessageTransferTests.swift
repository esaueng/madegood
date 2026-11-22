import WatchConnectivity
import WaterKit
import XCTest

@testable import MadeGood

/// The fast path (docs/watch-transfer.md, `MessageTransfer`): parts and small files sent as
/// message chunks while the watch app is open and the phone reachable, assembled on the
/// phone and stored through the same path as a received file.
final class MessageTransferTests: XCTestCase {
    private typealias Unit = RecordingTransfer.Unit
    private typealias UnitKey = RecordingTransfer.UnitKey

    private let sessionId = "00000000-0000-4000-8000-000000000001"
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func bytes(_ count: Int, seed: UInt64 = 7) -> Data {
        var state = seed
        return Data(
            (0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 33)
            })
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func chunk(
        _ data: Data, file: String = "motion.ndjson.gz", part: TransferParts.Part?, from offset: Int, size: Int
    ) -> MessageTransfer.Chunk {
        let end = min(offset + size, data.count)
        return MessageTransfer.Chunk(
            sessionId: sessionId, file: file, part: part, length: Int64(data.count), crc: MessageTransfer.crc32(data),
            offset: Int64(offset), data: data.subdata(in: offset..<end))
    }

    /// What the phone answers a chunk with, as `RecordingTransfer` does before storing.
    private func phoneReply(to frame: Data, in recording: URL) throws -> (MessageTransfer.Reply, URL?) {
        let chunk = try MessageTransfer.decode(frame)
        switch try MessageTransfer.write(chunk, in: recording) {
        case .partial(let have): return (.init(have: have), nil)
        case .complete(let url): return (.init(have: chunk.length, done: true), url)
        }
    }

    /// Runs the watch's loop for one unit: send from `start`, follow each reply's step until
    /// the phone has the unit. Returns the assembled file and the messages sent.
    private func deliver(
        _ data: Data, file: String = "motion.ndjson.gz", part: TransferParts.Part?, chunkSize: Int,
        from start: Int64 = 0, stopAfter: Int? = nil, in recording: URL
    ) throws -> (url: URL?, messages: Int) {
        var offset = start
        var stalls = 0
        var messages = 0
        while true {
            if let stopAfter, messages == stopAfter { return (nil, messages) }
            let frame = MessageTransfer.encode(chunk(data, file: file, part: part, from: Int(offset), size: chunkSize))
            messages += 1
            let (reply, url) = try phoneReply(to: frame, in: recording)
            switch MessageTransfer.step(after: reply, sentFrom: offset, length: Int64(data.count), stalls: &stalls) {
            case .send(let from): offset = from
            case .delivered: return (url, messages)
            case .failed(let why): XCTFail(why); return (nil, messages)
            }
        }
    }

    // MARK: Chunk size and fallback

    func testTheChunkSizeHalvesOnPayloadTooLargeDownToTheSmallest() {
        var sizes = [MessageTransfer.largestChunk]
        while let next = MessageTransfer.smallerChunk(after: sizes.last!) { sizes.append(next) }
        XCTAssertEqual(sizes, [60 << 10, 30 << 10, 15 << 10, 7680, 4 << 10])
        XCTAssertNil(MessageTransfer.smallerChunk(after: MessageTransfer.smallestChunk))
    }

    func testAFrameOfTheLargestChunkStaysUnderTheReportedMessageLimit() {
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: 35 << 20)[34]
        let frame = MessageTransfer.encode(
            chunk(bytes(Int(part.length)), part: part, from: 0, size: MessageTransfer.largestChunk))
        XCTAssertLessThan(frame.count, 64 * 1000)
    }

    func testErrorsAreSortedIntoSmallerChunkFilesWithoutPauseAndFilesWithPause() {
        func error(_ code: WCError.Code) -> NSError { NSError(domain: WCErrorDomain, code: code.rawValue) }
        XCTAssertEqual(MessageTransfer.classify(error(.payloadTooLarge)), .tooLarge)
        XCTAssertEqual(MessageTransfer.classify(error(.notReachable)), .unreachable)
        XCTAssertEqual(MessageTransfer.classify(error(.messageReplyTimedOut)), .other)
        XCTAssertEqual(MessageTransfer.classify(error(.deliveryFailed)), .other)
        XCTAssertEqual(MessageTransfer.classify(NSError(domain: NSCocoaErrorDomain, code: 7009)), .other)
    }

    func testMessagesGoOnlyWhileTheAppIsOpenAndThePhoneReachableAndTakesThem() {
        func may(
            foreground: Bool = true, activated: Bool = true, reachable: Bool = true, takes: Bool = true,
            disabled: Bool = false, pausedUntil: Date? = nil
        ) -> Bool {
            MessageTransfer.mayUse(
                foreground: foreground, activated: activated, reachable: reachable, phoneTakesMessages: takes,
                disabled: disabled, pausedUntil: pausedUntil, now: now)
        }
        XCTAssertTrue(may())
        // The background is files only.
        XCTAssertFalse(may(foreground: false))
        XCTAssertFalse(may(activated: false))
        XCTAssertFalse(may(reachable: false))
        // An iPhone build without the handler.
        XCTAssertFalse(may(takes: false))
        // Messages too large even at the smallest chunk.
        XCTAssertFalse(may(disabled: true))
        // Paused after a failure, then allowed again.
        XCTAssertFalse(may(pausedUntil: now.addingTimeInterval(30)))
        XCTAssertTrue(may(pausedUntil: now))
    }

    func testOnlyAPhoneThatSaysItTakesChunksGetsMessages() {
        XCTAssertFalse(RecordingTransfer.phoneTakesMessages(fromContext: [:]))
        XCTAssertFalse(RecordingTransfer.phoneTakesMessages(fromContext: ["rawVersions": [1, 2]]))
        XCTAssertTrue(RecordingTransfer.phoneTakesMessages(fromContext: ["messageTransfer": MessageTransfer.version]))
        XCTAssertFalse(
            RecordingTransfer.phoneTakesMessages(fromContext: ["messageTransfer": MessageTransfer.version + 1]))
    }

    // MARK: Frames

    func testAChunkRoundTripsThroughAMessage() throws {
        let data = bytes(5000)
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20)[1]
        let partChunk = chunk(bytes(Int(part.length)), part: part, from: 4096, size: 4096)
        XCTAssertEqual(try MessageTransfer.decode(MessageTransfer.encode(partChunk)), partChunk)
        let whole = chunk(data, file: RawFormat.metaFileName, part: nil, from: 0, size: 60 << 10)
        XCTAssertEqual(try MessageTransfer.decode(MessageTransfer.encode(whole)), whole)

        let reply = MessageTransfer.Reply(have: 123, done: false, error: "no")
        XCTAssertEqual(MessageTransfer.decodeReply(MessageTransfer.encode(reply)), reply)
        XCTAssertNil(MessageTransfer.decodeReply(Data("x".utf8)))
    }

    func testThePhoneRefusesChunksThatCannotBeRight() {
        let data = bytes(100)
        XCTAssertThrowsError(try MessageTransfer.decode(Data("hello".utf8)))
        XCTAssertThrowsError(try MessageTransfer.decode(Data("MGT1\u{0}\u{0}\u{0}\u{ff}".utf8)))
        // Past the end of the unit.
        var past = chunk(data, part: nil, from: 0, size: 100)
        past.offset = 50
        XCTAssertThrowsError(try MessageTransfer.decode(MessageTransfer.encode(past)))
        // A part whose length disagrees with its layout.
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20)[0]
        var wrong = chunk(data, part: part, from: 0, size: 100)
        wrong.length = 100
        XCTAssertThrowsError(try MessageTransfer.decode(MessageTransfer.encode(wrong)))
        // A whole file larger than a part always goes in parts.
        var large = chunk(data, part: nil, from: 0, size: 100)
        large.length = TransferParts.partSize + 1
        XCTAssertThrowsError(try MessageTransfer.decode(MessageTransfer.encode(large)))
    }

    func testTheChecksumIsCRC32() {
        XCTAssertEqual(MessageTransfer.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(MessageTransfer.crc32(Data()), 0)
    }

    // MARK: Reassembly

    /// Every invariant at once: a file sent as parts, each part as chunks, assembled,
    /// stored and joined on the phone, is byte-identical to the watch's.
    func testPartsSentAsChunksJoinIntoTheOriginal() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        let original = bytes(Int(TransferParts.partSize) * 2 + 12345)
        try original.write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        for part in TransferParts.plan(file: "motion.ndjson.gz", size: Int64(original.count)) {
            let unit = Unit(file: part.file, part: part, length: part.length)
            let data = try MessageTransfer.read(unit, in: watch)
            let (url, messages) = try deliver(data, part: part, chunkSize: MessageTransfer.largestChunk, in: phone)
            XCTAssertEqual(messages, Int((part.length + Int64(60 << 10) - 1) / Int64(60 << 10)))
            XCTAssertEqual(try TransferParts.store(XCTUnwrap(url), as: part, in: phone), .stored)
        }
        let ready = try XCTUnwrap(TransferParts.complete(in: phone).first)
        let joined = try XCTUnwrap(TransferParts.join(ready, in: phone, stagingPrefix: ".incoming-"))
        XCTAssertEqual(try Data(contentsOf: joined), original)
    }

    func testASmallFileSentWholeByMessageIsTheOriginal() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        let original = bytes(70_000)
        try original.write(to: watch.appendingPathComponent("heading.ndjson.gz"))
        let unit = Unit(file: "heading.ndjson.gz", part: nil, length: Int64(original.count))
        let data = try MessageTransfer.read(unit, in: watch)
        let (url, messages) = try deliver(
            data, file: unit.file, part: nil, chunkSize: MessageTransfer.smallestChunk, in: phone)
        XCTAssertEqual(messages, 18)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), original)
        // Assembling never makes a recording file: only the store path does.
        XCTAssertEqual(RecordingTransfer.recordingFiles(in: phone), [:])
        XCTAssertEqual(TransferParts.held(in: phone), [:])
    }

    func testAnEmptyFileArrivesInOneMessage() throws {
        let phone = try folder("phone")
        let (url, messages) = try deliver(Data(), file: "heading.ndjson.gz", part: nil, chunkSize: 4096, in: phone)
        XCTAssertEqual(messages, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), Data())
    }

    func testARepeatedChunkIsHarmless() throws {
        let phone = try folder("phone")
        let data = bytes(10_000)
        let first = MessageTransfer.encode(chunk(data, part: nil, from: 0, size: 4000))
        XCTAssertEqual(try phoneReply(to: first, in: phone).0, .init(have: 4000))
        // The reply was lost and the watch sends it again.
        XCTAssertEqual(try phoneReply(to: first, in: phone).0, .init(have: 4000))
        // An overlapping chunk (sent after a chunk size change) adds only what is new.
        let overlap = MessageTransfer.encode(chunk(data, part: nil, from: 2000, size: 4000))
        XCTAssertEqual(try phoneReply(to: overlap, in: phone).0, .init(have: 6000))
        let (url, _) = try deliver(data, part: nil, chunkSize: 4000, from: 6000, in: phone)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), data)
    }

    func testAChunkPastWhatThePhoneHoldsBringsTheWatchBack() throws {
        let phone = try folder("phone")
        let data = bytes(10_000)
        let skipped = MessageTransfer.encode(chunk(data, part: nil, from: 4000, size: 4000))
        XCTAssertEqual(try phoneReply(to: skipped, in: phone).0, .init(have: 0))
        var stalls = 0
        XCTAssertEqual(
            MessageTransfer.step(after: .init(have: 0), sentFrom: 4000, length: 10_000, stalls: &stalls),
            .send(from: 0))
    }

    /// Reachability drops mid-part: the phone keeps what it has; the next run, by message,
    /// starts at 0 and the first reply moves it to where the phone is, even with another
    /// chunk size.
    func testAPartCutOffMidwayResumesWhereThePhoneIs() throws {
        let phone = try folder("phone")
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20)[2]
        let data = bytes(Int(part.length), seed: 3)
        let cut = try deliver(data, part: part, chunkSize: 60 << 10, stopAfter: 7, in: phone)
        XCTAssertNil(cut.url)
        let resumed = try deliver(data, part: part, chunkSize: 30 << 10, in: phone)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(resumed.url)), data)
        // One repeated chunk to learn where the phone is, then the rest.
        let rest = Int(part.length) - 7 * (60 << 10)
        XCTAssertEqual(resumed.messages, 1 + (rest + (30 << 10) - 1) / (30 << 10))
    }

    func testAUnitThatDoesNotMatchItsChecksumIsDropped() throws {
        let phone = try folder("phone")
        let data = bytes(8000)
        var bad = chunk(data, part: nil, from: 0, size: 8000)
        bad.crc ^= 1
        XCTAssertThrowsError(try MessageTransfer.write(bad, in: phone)) {
            XCTAssertEqual($0 as? MessageTransfer.FrameError, .checksumMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: MessageTransfer.stagingURL(bad, in: phone).path))
    }

    func testUnitsOfOtherContentOrLayoutNeverMix() {
        let phone = root!
        let a = chunk(bytes(100), part: nil, from: 0, size: 10)
        let b = chunk(bytes(100, seed: 9), part: nil, from: 0, size: 10)
        XCTAssertNotEqual(MessageTransfer.stagingURL(a, in: phone), MessageTransfer.stagingURL(b, in: phone))
        let small = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20, partSize: 1 << 19)[0]
        let large = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20)[0]
        let data = bytes(1 << 19)
        XCTAssertNotEqual(
            MessageTransfer.stagingURL(chunk(data, part: small, from: 0, size: 10), in: phone),
            MessageTransfer.stagingURL(chunk(bytes(1 << 20), part: large, from: 0, size: 10), in: phone))
    }

    // MARK: Duplicates across the two paths

    func testAPartArrivingByBothPathsIsStoredOnceAndItsStagingGoes() throws {
        let watch = try folder("watch")
        let phone = try folder("phone")
        let original = bytes(Int(TransferParts.partSize) + 500)
        try original.write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        let part = TransferParts.plan(file: "motion.ndjson.gz", size: Int64(original.count))[0]
        let data = try MessageTransfer.read(Unit(file: part.file, part: part, length: part.length), in: watch)
        let messageChunk = chunk(data, part: part, from: 0, size: 60 << 10)
        XCTAssertFalse(RecordingTransfer.holds(messageChunk, in: phone))

        // Half arrived by message, then the file transfer of the same part.
        _ = try deliver(data, part: part, chunkSize: 60 << 10, stopAfter: 8, in: phone)
        let file = try TransferParts.slice(part, in: watch)
        XCTAssertEqual(try TransferParts.store(file, as: part, in: phone), .stored)
        MessageTransfer.removeStaging(of: part, in: phone)
        XCTAssertTrue(RecordingTransfer.holds(messageChunk, in: phone))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MessageTransfer.stagingURL(messageChunk, in: phone).path))

        // The whole unit by message too: the store keeps the part it has.
        let (url, _) = try deliver(data, part: part, chunkSize: 60 << 10, in: phone)
        XCTAssertEqual(try TransferParts.store(XCTUnwrap(url), as: part, in: phone), .alreadyHad)
        MessageTransfer.removeStaging(of: part, in: phone)
        XCTAssertEqual(TransferParts.held(in: phone), [TransferParts.layoutKey(part): [0]])
    }

    func testAPhoneHoldingTheJoinedFileHoldsEveryPartOfIt() throws {
        let phone = try folder("phone")
        let parts = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20)
        let c = chunk(bytes(Int(parts[1].length)), part: parts[1], from: 0, size: 10)
        XCTAssertFalse(RecordingTransfer.holds(c, in: phone))
        try bytes(3 << 20).write(to: phone.appendingPathComponent("motion.ndjson.gz"))
        XCTAssertTrue(RecordingTransfer.holds(c, in: phone))
        // A whole file is held only at its own length.
        let whole = chunk(bytes(10), file: RawFormat.metaFileName, part: nil, from: 0, size: 10)
        try bytes(11).write(to: phone.appendingPathComponent(RawFormat.metaFileName))
        XCTAssertFalse(RecordingTransfer.holds(whole, in: phone))
        try bytes(10).write(to: phone.appendingPathComponent(RawFormat.metaFileName))
        XCTAssertTrue(RecordingTransfer.holds(whole, in: phone))
    }

    func testStagingIsRemovedPerFileAndPerPart() throws {
        let phone = try folder("phone")
        let parts = TransferParts.plan(file: "motion.ndjson.gz", size: 3 << 20)
        let first = chunk(bytes(Int(parts[0].length)), part: parts[0], from: 0, size: 100)
        let second = chunk(bytes(Int(parts[1].length)), part: parts[1], from: 0, size: 100)
        let other = chunk(bytes(500), file: "heading.ndjson.gz", part: nil, from: 0, size: 100)
        for c in [first, second, other] { _ = try MessageTransfer.write(c, in: phone) }
        let exists = { (c: MessageTransfer.Chunk) in
            FileManager.default.fileExists(atPath: MessageTransfer.stagingURL(c, in: phone).path)
        }
        MessageTransfer.removeStaging(of: parts[0], in: phone)
        XCTAssertEqual([exists(first), exists(second), exists(other)], [false, true, true])
        MessageTransfer.removeStaging(file: "motion.ndjson.gz", in: phone)
        XCTAssertEqual([exists(second), exists(other)], [false, true])
        MessageTransfer.removeStaging(file: "heading.ndjson.gz", in: phone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.appendingPathComponent(".messages").path))
    }

    // MARK: Watch: steps

    func testTheWatchFollowsThePhonesReplies() {
        var stalls = 0
        XCTAssertEqual(
            MessageTransfer.step(after: .init(have: 4096), sentFrom: 0, length: 10_000, stalls: &stalls),
            .send(from: 4096))
        XCTAssertEqual(
            MessageTransfer.step(
                after: .init(have: 10_000, done: true), sentFrom: 8192, length: 10_000, stalls: &stalls),
            .delivered)
        if case .failed = MessageTransfer.step(
            after: .init(have: 0, error: "no"), sentFrom: 0, length: 10_000, stalls: &stalls)
        {
        } else {
            XCTFail("an error is a failure")
        }
        for have: Int64 in [-1, 10_001, 10_000] {
            if case .failed = MessageTransfer.step(
                after: .init(have: have), sentFrom: 0, length: 10_000, stalls: &stalls)
            {
            } else {
                XCTFail("\(have) bytes held is a failure")
            }
        }
    }

    func testAPhoneThatNeverTakesTheChunkStopsTheFastPath() {
        var stalls = 0
        let reply = MessageTransfer.Reply(have: 4096)
        XCTAssertEqual(
            MessageTransfer.step(after: reply, sentFrom: 4096, length: 10_000, stalls: &stalls), .send(from: 4096))
        XCTAssertEqual(
            MessageTransfer.step(after: reply, sentFrom: 4096, length: 10_000, stalls: &stalls), .send(from: 4096))
        if case .failed = MessageTransfer.step(after: reply, sentFrom: 4096, length: 10_000, stalls: &stalls) {
        } else {
            XCTFail("the third reply without progress is a failure")
        }
        // Progress resets the count.
        stalls = 2
        XCTAssertEqual(
            MessageTransfer.step(after: .init(have: 8192), sentFrom: 4096, length: 10_000, stalls: &stalls),
            .send(from: 8192))
        XCTAssertEqual(stalls, 0)
    }

    // MARK: Watch: interleaving with files

    private let local: [String: Int64] = [
        RawFormat.metaFileName: 700, "heading.ndjson.gz": 3000, "motion.ndjson.gz": 4 << 20,
    ]

    private func motion(_ index: Int) -> TransferParts.Part {
        TransferParts.plan(file: "motion.ndjson.gz", size: 4 << 20)[index]
    }

    private func names(_ units: [Unit]) -> [String] {
        units.map { $0.part.map { "\($0.file)#\($0.index)" } ?? $0.file }
    }

    /// Fast-path candidates as `RecordingTransfer.fastPathCandidates` builds them.
    private func candidates(
        moving: Set<UnitKey> = [], queued: Set<UnitKey> = [], claimed: Set<UnitKey> = [],
        handedOver: Set<UnitKey> = [], holds: RecordingTransfer.PhoneHolds? = nil
    ) -> [Unit] {
        let units = RecordingTransfer.units(
            local: local, holds: holds, inFlight: moving.union(claimed), handedOver: handedOver, window: Int.max / 2)
        return MessageTransfer.order(units, queuedAsFiles: queued)
    }

    func testTheFastPathTakesWhatNoFileCarriesFirstAndMetaLast() {
        XCTAssertEqual(
            names(candidates()),
            [
                "heading.ndjson.gz", "motion.ndjson.gz#0", "motion.ndjson.gz#1", "motion.ndjson.gz#2",
                "motion.ndjson.gz#3", RawFormat.metaFileName,
            ])
    }

    /// A file transfer that is moving is never sent by message too; files queued but not
    /// started go after everything else, the last queued first, so the file the queue starts
    /// next is the last one taken.
    func testAFileMovingIsNeverSentByMessageAndQueuedOnesGoLast() {
        let moving: Set<UnitKey> = [UnitKey(motion(0))]
        let queued: Set<UnitKey> = [UnitKey(motion(1)), UnitKey(motion(2))]
        XCTAssertEqual(
            names(candidates(moving: moving, queued: queued)),
            [
                "heading.ndjson.gz", "motion.ndjson.gz#3", "motion.ndjson.gz#2", "motion.ndjson.gz#1",
                RawFormat.metaFileName,
            ])
    }

    func testAUnitOnItsWayByMessageIsNotQueuedAsAFile() {
        // The fast path stopped (the app left the screen) with a part on its way: the send
        // that follows counts it in flight while its claim lasts.
        let claimed: Set<UnitKey> = [UnitKey(motion(2))]
        let files = RecordingTransfer.units(local: local, holds: nil, inFlight: claimed, window: 32)
        XCTAssertFalse(names(files).contains("motion.ndjson.gz#2"))
        XCTAssertTrue(names(files).contains("motion.ndjson.gz#3"))
    }

    func testAUnitDeliveredByMessageIsNotSentAgainEitherWay() {
        // The reply says stored; until the acknowledgement lists it, it is handed over.
        let handed: Set<UnitKey> = [UnitKey(motion(0)), .whole("heading.ndjson.gz")]
        XCTAssertEqual(
            names(candidates(handedOver: handed)),
            ["motion.ndjson.gz#1", "motion.ndjson.gz#2", "motion.ndjson.gz#3", RawFormat.metaFileName])
        XCTAssertFalse(
            names(RecordingTransfer.units(local: local, holds: nil, inFlight: [], handedOver: handed, window: 32))
                .contains("motion.ndjson.gz#0"))
    }

    /// Found while testing this: a whole file stored by message was not handed over, so the
    /// fast path sent it again and again (each time answered "held") until the
    /// acknowledgement arrived.
    func testAWholeFileOrMetaDeliveredByMessageIsNotSentAgainBeforeItsAcknowledgement() {
        let all = Set(TransferParts.plan(file: "motion.ndjson.gz", size: 4 << 20).map(UnitKey.init))
        XCTAssertEqual(names(candidates(handedOver: all.union([.whole("heading.ndjson.gz")]))), [RawFormat.metaFileName])
        XCTAssertEqual(
            names(candidates(handedOver: all.union([.whole("heading.ndjson.gz"), .whole(RawFormat.metaFileName)]))),
            [])
    }

    func testAClaimLastsOnlyWhileRepliesCome() {
        let unit = Unit(file: "heading.ndjson.gz", part: nil, length: 3000)
        let run = RecordingTransfer.FastRun(
            generation: 1, sessionId: sessionId, unit: unit, data: Data(), crc: 0, startedAt: now, lastActivity: now)
        XCTAssertTrue(run.isLive(now: now.addingTimeInterval(MessageTransfer.claimGrace - 1)))
        XCTAssertFalse(run.isLive(now: now.addingTimeInterval(MessageTransfer.claimGrace)))
    }

    func testTheWatchReadsExactlyTheUnit() throws {
        let watch = try folder("watch")
        let original = bytes(Int(TransferParts.partSize) + 10)
        try original.write(to: watch.appendingPathComponent("motion.ndjson.gz"))
        let parts = TransferParts.plan(file: "motion.ndjson.gz", size: Int64(original.count))
        XCTAssertEqual(
            try MessageTransfer.read(Unit(file: "motion.ndjson.gz", part: parts[1], length: 10), in: watch),
            original.suffix(10))
        XCTAssertThrowsError(
            try MessageTransfer.read(
                Unit(file: "motion.ndjson.gz", part: nil, length: Int64(original.count) + 1), in: watch))
    }
}
