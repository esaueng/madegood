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
    func putSession(_ snapshot: SessionUploadSnapshot, bearer: String, policy: SessionNetworkPolicy) async throws {
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
                .init(path: .init(id: snapshot.sessionID.uuidString.lowercased()), body: .json(body)))
            {
            case .ok, .created: break
            default: throw VoyageAPIError.invalidResponse
            }
        }
    }

    /// `PUT /sessions/{id}/track`: the gzipped track v1 bytes, read from `file` by the
    /// transport. Repeating it replaces the stored file.
    func putTrack(
        file: URL, sessionID: UUID, taskDescription: String, bearer: String, policy: SessionNetworkPolicy
    ) async throws {
        let upload = GeneratedSessionTransport.FileUpload(file: file, taskDescription: taskDescription)
        try await perform(bearer: bearer, policy: policy, upload: upload) { client in
            // The body is never read: the transport uploads the file itself.
            _ = try await client.putSessionTrack(
                .init(path: .init(id: sessionID.uuidString.lowercased()), body: .application_gzip(HTTPBody()))
            ).noContent
        }
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
        guard let path = request.path else { throw VoyageAPIError.invalidResponse }
        var absolute = HTTPRequest(method: request.method, url: baseURL.appending(path: path))
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
