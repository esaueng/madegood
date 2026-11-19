import CoreLocation
import XCTest

final class PhoneVoyageLoopbackUITests: XCTestCase {
    @MainActor
    func testSharingAndIndependentPrivateSyncAgainstLocalWorker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["MADEGOOD_TEST_WORKER_PORT"].flatMap(UInt16.init),
            let owner = environment["MADEGOOD_TEST_VOYAGE_TOKEN"],
            let refresh = environment["MADEGOOD_TEST_VOYAGE_REFRESH_TOKEN"],
            let account = environment["MADEGOOD_TEST_VOYAGE_ACCOUNT"],
            let outsider = environment["MADEGOOD_TEST_VOYAGE_OUTSIDER"]
        else { throw XCTSkip("Requires the synthetic loopback Worker fixture") }

        continueAfterFailure = false
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 25
        settings.timeoutIntervalForResource = 90
        let http = URLSession(configuration: settings)
        let app = XCUIApplication()
        app.launchArguments = ["-localVoyageSharing"]
        app.launchEnvironment = [
            "MADEGOOD_TEST_WORKER_PORT": String(port),
            "MADEGOOD_TEST_VOYAGE_TOKEN": owner,
            "MADEGOOD_TEST_VOYAGE_REFRESH_TOKEN": refresh,
            "MADEGOOD_TEST_VOYAGE_ACCOUNT": account,
            "MADEGOOD_TEST_VOYAGES": UUID().uuidString,
        ]
        resetLocationPermission(app)
        launchFresh(app)
        defer {
            XCUIDevice.shared.location = nil
            app.terminate()
            http.invalidateAndCancel()
        }
        let voyagesTab = app.tabBars.buttons["Voyages"]
        XCTAssertTrue(voyagesTab.waitForExistence(timeout: 15))
        voyagesTab.tap()
        createVoyage("Synthetic live passage", in: app)
        startLeg(in: app, at: 0.02)
        let initial = app.staticTexts["Position unavailable"]
        let start = app.buttons["Start Sharing"]
        scrollTo(start, in: app)
        start.tap()
        let consent = app.sheets.buttons["Start Sharing"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        consent.tap()

        let link = element("voyageSharing.link", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        let linkURL = try XCTUnwrap((link.value as? String).flatMap(URL.init(string:)))
        XCTAssertEqual(linkURL.host(), base.host())
        XCTAssertEqual(linkURL.port, base.port)
        scrollTo(initial, in: app)

        let viewerPath = "live/\(linkURL.lastPathComponent)"
        let emptySnapshot = try await request(viewerPath, base: base, session: http)
        XCTAssertEqual(try status(emptySnapshot.0), "unavailable")
        var socketURL = URLComponents(url: base.appending(path: "api/\(viewerPath)"), resolvingAgainstBaseURL: false)!
        socketURL.scheme = "ws"
        let socket = http.webSocketTask(with: socketURL.url!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let initialFrame = try await frame(socket)
        XCTAssertEqual(try status(initialFrame), "unavailable")

        let delay = element("voyageSharing.delay", in: app)
        for _ in 0..<4 where !delay.isHittable { app.swipeDown() }
        delay.tap()
        app.buttons["No delay"].tap()
        let apply = app.buttons["Apply Delay"]
        scrollTo(apply, in: app)
        apply.tap()
        simulatePosition(longitude: 0.025)
        let visible = element("voyageSharing.visibleSegments", in: app)
        scrollTo(visible, in: app)
        let availableFrame = try await frame(socket, until: "available")
        let snapshot = try await request(viewerPath, base: base, session: http)
        XCTAssertEqual(try status(snapshot.0), "available")
        let projected = try XCTUnwrap(try JSONSerialization.jsonObject(with: snapshot.0) as? NSDictionary)
        XCTAssertEqual(projected, try JSONSerialization.jsonObject(with: availableFrame) as? NSDictionary)
        let current = try XCTUnwrap(projected["current"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(current["lon"]), 0.025, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(current["lat"]), 0, accuracy: 0.00001)
        XCTAssertEqual(visible.value as? String, "1")

        app.swipeDown()
        let stop = app.buttons["Stop Sharing"]
        scrollTo(stop, in: app)
        stop.tap()
        let clearedFrame = try await frame(socket, until: "unavailable")
        XCTAssertEqual(try status(clearedFrame), "unavailable")
        let cleared = try await request(viewerPath, base: base, session: http)
        XCTAssertEqual(try status(cleared.0), "unavailable")
        let off = app.buttons["Start Sharing"]
        XCTAssertTrue(off.waitForExistence(timeout: 15))
        XCTAssertFalse(link.exists)
        XCTAssertFalse(visible.exists)

        for _ in 0..<3 where !app.buttons["End Leg"].isHittable { app.swipeDown() }
        app.buttons["End Leg"].tap()
        app.navigationBars.buttons["Voyages"].tap()
        let privateTitle = "Synthetic private \(UUID().uuidString.prefix(8))"
        createVoyage(privateTitle, in: app)
        startLeg(in: app, at: -0.025)
        app.buttons["End Leg"].tap()
        let savedLeg = app.buttons["voyage.savedLeg"]
        scrollTo(savedLeg, in: app)
        savedLeg.tap()
        let privateSync = app.buttons["Sync Leg Privately"]
        scrollTo(privateSync, in: app)
        privateSync.tap()
        app.buttons["Sync Privately"].tap()
        waitForLabel(app.staticTexts["voyageSync.legStatus"], "Synced", timeout: 35)

        let voyages = try await request("voyages", bearer: owner, base: base, session: http)
        let list = try records("voyages", from: voyages.0)
        let privateID = try XCTUnwrap(list.first { $0["title"] == privateTitle }?["id"])
        let privatePath = "voyages/\(privateID)"
        let ownerState = try await request("\(privatePath)/sharing", bearer: owner, base: base, session: http)
        XCTAssertEqual(try recordsObject(ownerState.0)["sharing"] as? String, "off")
        let legs = try await request("\(privatePath)/legs", bearer: owner, base: base, session: http)
        let leg = try XCTUnwrap(try records("legs", from: legs.0).first?["id"])
        let trackPath = "\(privatePath)/legs/\(leg)/track"
        let track = try await request(trackPath, bearer: owner, base: base, session: http)
        XCTAssertEqual(track.1, 200)
        XCTAssertEqual(Data(track.0.prefix(2)), Data([0x1f, 0x8b]))
        let forbidden = try await request(trackPath, bearer: outsider, base: base, session: http)
        XCTAssertEqual(forbidden.1, 404)
    }

    @MainActor
    private func createVoyage(_ title: String, in app: XCUIApplication) {
        app.buttons["New Voyage"].tap()
        let form = app.alerts["New Voyage"]
        let field = form.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        form.buttons["Create"].tap()
    }

    @MainActor
    private func startLeg(in app: XCUIApplication, at longitude: Double) {
        let start = app.buttons["Start Leg"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        simulatePosition(longitude: longitude)
        XCTAssertTrue(element("voyage.lastSavedPosition", in: app).waitForExistence(timeout: 20))
    }

    @MainActor
    private func simulatePosition(longitude: Double) {
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: longitude),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3,
                timestamp: .now))
    }

    @MainActor
    private func request(_ path: String, bearer: String? = nil, base: URL, session: URLSession) async throws -> (
        Data, Int
    ) {
        var request = URLRequest(url: base.appending(path: "api/\(path)"))
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }

    @MainActor
    private func frame(_ socket: URLSessionWebSocketTask, until expected: String? = nil) async throws -> Data {
        for _ in 0..<12 {
            let data: Data
            switch try await socket.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: throw URLError(.cannotDecodeContentData)
            }
            if expected == nil || (try? status(data)) == expected { return data }
        }
        throw URLError(.cannotDecodeContentData)
    }

    private func status(_ data: Data) throws -> String? { try recordsObject(data)["status"] as? String }

    private func recordsObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func records(_ key: String, from data: Data) throws -> [[String: String]] {
        let items = try XCTUnwrap(try recordsObject(data)[key] as? [[String: Any]])
        return items.map { $0.compactMapValues { $0 as? String } }
    }
}
