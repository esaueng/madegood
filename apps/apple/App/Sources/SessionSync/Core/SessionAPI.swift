import Foundation
import HTTPTypes
import HTTPTypesFoundation
import OpenAPIRuntime

/// Sends session requests. Metadata goes through `send`; track files go through a
/// file-backed upload that a background URLSession can finish while the app is suspended.
/// Sign-in and refresh reuse the account plumbing of private Voyage sync (`VoyageTransport`).
@MainActor
protocol SessionSyncTransport: VoyageTransport {
    func upload(_ request: URLRequest, file: URL, taskDescription: String) async throws -> HTTPURLResponse
    /// Creates the background session now (at launch) and reports every finished
    /// background upload, including ones no caller is waiting for.
    func activate(onCompletion: @escaping @MainActor (_ taskDescription: String, _ statusCode: Int?) -> Void)
    /// Cancels every background upload for which `keep` returns false.
    func reconcileUploads(keep: (_ taskDescription: String?, _ request: URLRequest?) -> Bool) async
}

private struct SharingState: Decodable {
    let sharingEnabled: Bool
}

/// A session others can see, as Settings → Sharing lists it.
struct SharedSession: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let sport: String
    let title: String?
    /// `unlisted` or `public`.
    let visibility: String
    let startedAt: String
}

struct SharedSessionPage: Decodable, Sendable {
    let sessions: [SharedSession]
    let nextCursor: String?
}

/// A 412: the server stores another upload revision for the session (`Upload-Revision`).
struct SessionRevisionConflict: Error, Equatable {
    let stored: Int64
}

/// Which networks an upload may use: the Settings "Wi-Fi only" switch.
struct SessionNetworkPolicy: Equatable, Sendable {
    var allowsCellular = true
}

/// The session routes of openapi/openapi.json, through the generated client.
@MainActor
final class SessionAPI {
    private let baseURL: URL
    private let transport: any SessionSyncTransport

    init(baseURL: URL, transport: any SessionSyncTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `PUT /sessions/{id}`: idempotent, so a retry after a lost response is safe.
    func putSession(
        _ snapshot: SessionUploadSnapshot, revision: Int64, bearer: String, policy: SessionNetworkPolicy
    ) async throws {
        let summary = try snapshot.summary.map {
            try JSONDecoder().decode(
                Components.Schemas.PutSessionRequest.summaryPayload.self, from: JSONEncoder().encode($0))
        }
        guard let sport = Components.Schemas.PutSessionRequest.sportPayload(rawValue: snapshot.sport.rawValue) else {
            throw VoyageAPIError.invalidResponse
        }
        let body = Components.Schemas.PutSessionRequest(
            sport: sport, startedAt: snapshot.startedAt, endedAt: snapshot.endedAt,
            durationS: snapshot.durationS, movingS: snapshot.movingS, distanceM: snapshot.distanceM,
            maxSpeedMps: snapshot.maxSpeedMps, avgSpeedMps: snapshot.avgSpeedMps, summary: summary,
            analyzerVersion: snapshot.analyzerVersion
        )
        try await perform(bearer: bearer, policy: policy) { client in
            switch try await client.putSession(
                .init(
                    path: .init(id: snapshot.sessionID.uuidString.lowercased()), query: .init(revision: revision),
                    body: .json(body)))
            {
            case .ok, .created: break
            default: throw VoyageAPIError.invalidResponse
            }
        }
    }

    /// `PUT /sessions/{id}/track`: the gzipped track v1 bytes, read from `file` by the
    /// transport. Repeating it replaces the stored file.
    func putTrack(
        file: URL, sessionID: UUID, revision: Int64, taskDescription: String, bearer: String,
        policy: SessionNetworkPolicy
    ) async throws {
        let upload = GeneratedSessionTransport.FileUpload(file: file, taskDescription: taskDescription)
        try await perform(bearer: bearer, policy: policy, upload: upload) { client in
            // The body is never read: the transport uploads the file itself.
            _ = try await client.putSessionTrack(
                .init(
                    path: .init(id: sessionID.uuidString.lowercased()), query: .init(revision: revision),
                    body: .application_gzip(HTTPBody()))
            ).noContent
        }
    }

    /// `DELETE /me`: deletes the account `accountID` and everything uploaded to it (202: the
    /// server finishes in the background). The server refuses (409) if the token belongs to
    /// another account. Repeating it with the same access token succeeds. Built by hand: the
    /// generated client covers only the upload operations
    /// (Integrations/VoyageRecorder/swift-voyage-generator.yaml).
    func deleteAccount(accountID: String, bearer: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "me"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["userId": accountID])
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw VoyageAPIError.http(
                status: response.statusCode,
                code: (try? JSONDecoder().decode(Failure.self, from: data))?.error,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        }
    }

    // MARK: Sharing (Settings → Sharing). Built by hand like `deleteAccount`.

    /// `GET /me`: whether the account's sharing switch is on.
    func sharingEnabled(bearer: String) async throws -> Bool {
        let data = try await sendJSON("GET", path: "me", bearer: bearer)
        return try JSONDecoder().decode(SharingState.self, from: data).sharingEnabled
    }

    /// `PATCH /me {sharingEnabled}`. Off makes every session private on the server at once and
    /// keeps it so; on shares nothing by itself. Returns the switch as the server now has it.
    func setSharingEnabled(_ enabled: Bool, bearer: String) async throws -> Bool {
        let data = try await sendJSON(
            "PATCH", path: "me", body: try JSONEncoder().encode(["sharingEnabled": enabled]), bearer: bearer)
        return try JSONDecoder().decode(SharingState.self, from: data).sharingEnabled
    }

    /// `GET /sessions?shared=true`: one page of the sessions others can see, newest first.
    func sharedSessions(cursor: String?, bearer: String) async throws -> SharedSessionPage {
        var query = [URLQueryItem(name: "shared", value: "true"), URLQueryItem(name: "limit", value: "100")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await sendJSON("GET", path: "sessions", query: query, bearer: bearer)
        return try JSONDecoder().decode(SharedSessionPage.self, from: data)
    }

    /// `PATCH /sessions/{id} {visibility: private}`: stops sharing one session.
    func makePrivate(sessionID: String, bearer: String) async throws {
        _ = try await sendJSON(
            "PATCH", path: "sessions/\(sessionID)",
            body: try JSONEncoder().encode(["visibility": "private"]), bearer: bearer)
    }

    private func sendJSON(
        _ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, bearer: String
    ) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw VoyageAPIError.http(
                status: response.statusCode,
                code: (try? JSONDecoder().decode(Failure.self, from: data))?.error,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        }
        return data
    }

    private func perform<Result>(
        bearer: String, policy: SessionNetworkPolicy, upload: GeneratedSessionTransport.FileUpload? = nil,
        _ operation: (Client) async throws -> Result
    ) async throws -> Result {
        let client = Client(
            serverURL: baseURL,
            configuration: .init(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: GeneratedSessionTransport(
                transport: transport, bearer: bearer, policy: policy, fileUpload: upload)
        )
        do {
            return try await operation(client)
        } catch let error as ClientError {
            // The outbox classifies the HTTP status or the transport error.
            throw error.underlyingError
        }
    }
}

@MainActor
private struct GeneratedSessionTransport: ClientTransport {
    struct FileUpload {
        let file: URL
        let taskDescription: String
    }

    let transport: any SessionSyncTransport
    let bearer: String
    let policy: SessionNetworkPolicy
    let fileUpload: FileUpload?

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // The generated path carries the query (`?revision=`): keep it out of the path.
        guard let path = request.path, let parts = URLComponents(string: path),
            var components = URLComponents(
                url: baseURL.appending(path: parts.path), resolvingAgainstBaseURL: false)
        else { throw VoyageAPIError.invalidResponse }
        components.percentEncodedQuery = parts.percentEncodedQuery
        guard let url = components.url else { throw VoyageAPIError.invalidResponse }
        var absolute = HTTPRequest(method: request.method, url: url)
        absolute.headerFields = request.headerFields
        absolute.headerFields[.authorization] = "Bearer " + bearer
        guard var request = URLRequest(httpRequest: absolute) else { throw VoyageAPIError.invalidResponse }
        request.allowsCellularAccess = policy.allowsCellular
        request.allowsExpensiveNetworkAccess = policy.allowsCellular

        let data: Data
        let response: HTTPURLResponse
        if let fileUpload {
            request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
            response = try await transport.upload(request, file: fileUpload.file, taskDescription: fileUpload.taskDescription)
            data = Data()
        } else {
            if let body { request.httpBody = try await Data(collecting: body, upTo: 128 * 1024) }
            (data, response) = try await transport.send(request)
        }
        if response.statusCode == 412,
            let stored = response.value(forHTTPHeaderField: "Upload-Revision").flatMap({ Int64($0) })
        {
            throw SessionRevisionConflict(stored: stored)
        }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String }
            throw VoyageAPIError.http(
                status: response.statusCode,
                code: (try? JSONDecoder().decode(Failure.self, from: data))?.error,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            )
        }
        guard let http = response.httpResponse else { throw VoyageAPIError.invalidResponse }
        return (http, data.isEmpty ? nil : HTTPBody(data))
    }
}
