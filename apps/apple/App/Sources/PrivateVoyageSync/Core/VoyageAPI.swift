import Foundation
import HTTPTypes
import HTTPTypesFoundation
import OpenAPIRuntime

// Wire models for the private writes in openapi/openapi.json. Recorder models can
// change independently. These values are frozen when a completed leg is queued.
struct VoyageSnapshot: Codable, Equatable, Sendable {
    let title: String
    var boatName: String? = nil
    let startedAt: Date
    var endedAt: Date? = nil
}

struct VoyageLegSnapshot: Codable, Equatable, Sendable {
    var fromName: String? = nil
    var toName: String? = nil
    let startedAt: Date
    let endedAt: Date
    var distanceM: Double? = nil
}

struct CompletedVoyageLeg: Sendable {
    let voyageID: UUID
    let voyage: VoyageSnapshot
    let legID: UUID
    let leg: VoyageLegSnapshot
}

struct VoyageTokenPair: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

enum VoyageAPIError: Error, Equatable {
    case invalidResponse
    case http(status: Int, code: String?, retryAfter: TimeInterval?)

    var status: Int? {
        if case .http(let status, _, _) = self { return status }
        return nil
    }
}

struct VoyageUploadKey: Codable, Equatable, Sendable {
    let signInID: UUID
    let voyageID: UUID
    let legID: UUID

    var taskDescription: String {
        [signInID, voyageID, legID].map { $0.uuidString.lowercased() }.joined(separator: "/")
    }
}

@MainActor
protocol VoyageTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(_ request: URLRequest, file: URL, key: VoyageUploadKey) async throws -> HTTPURLResponse
    func cancelStaleUploads(currentSignIn: () -> UUID?) async
}

@MainActor
final class VoyageAPI {
    private let baseURL: URL
    private let transport: any VoyageTransport

    init(baseURL: URL, transport: any VoyageTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func signIn(identityToken: String, displayName: String?) async throws -> Components.Schemas.SignInResponse {
        try await perform { client in
            try await client.post_sol_auth_sol_apple(
                .init(body: .json(.init(identityToken: identityToken, displayName: displayName)))
            ).ok.body.json
        }
    }

    func refresh(_ refreshToken: String) async throws -> VoyageTokenPair {
        try await perform { client in
            let tokens = try await client.post_sol_auth_sol_refresh(
                .init(body: .json(.init(refreshToken: refreshToken)))
            ).ok.body.json
            return VoyageTokenPair(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
        }
    }

    func putVoyage(_ voyage: VoyageSnapshot, id: UUID, bearer: String) async throws {
        try await perform(bearer: bearer) { client in
            let result = try await client.putVoyage(
                .init(
                    path: .init(voyageId: id.uuidString.lowercased()),
                    body: .json(.init(
                        title: voyage.title, boatName: voyage.boatName,
                        startedAt: voyage.startedAt, endedAt: voyage.endedAt
                    ))
                )
            )
            switch result {
            case .ok, .created: break
            default: throw VoyageAPIError.invalidResponse
            }
        }
    }

    func putLeg(_ leg: VoyageLegSnapshot, voyageID: UUID, legID: UUID, bearer: String) async throws {
        try await perform(bearer: bearer) { client in
            let result = try await client.putVoyageLeg(
                .init(
                    path: .init(voyageId: voyageID.uuidString.lowercased(), legId: legID.uuidString.lowercased()),
                    body: .json(.init(
                        fromName: leg.fromName, toName: leg.toName,
                        startedAt: leg.startedAt, endedAt: leg.endedAt, distanceM: leg.distanceM
                    ))
                )
            )
            switch result {
            case .ok, .created: break
            default: throw VoyageAPIError.invalidResponse
            }
        }
    }

    func putTrack(file: URL, key: VoyageUploadKey, bearer: String) async throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let bytes = AsyncThrowingStream<HTTPBody.ByteChunk, Error>(unfolding: {
            guard let block = try handle.read(upToCount: 64 * 1024), !block.isEmpty else { return nil }
            return ArraySlice(block)
        })
        let body = HTTPBody(bytes, length: size.map { .known(Int64($0)) } ?? .unknown)
        try await perform(bearer: bearer, upload: .init(file: file, key: key)) { client in
            _ = try await client.putVoyageLegTrack(
                .init(
                    path: .init(voyageId: key.voyageID.uuidString.lowercased(), legId: key.legID.uuidString.lowercased()),
                    body: .application_gzip(body)
                )
            ).noContent
        }
    }

    private func perform<Result>(
        bearer: String? = nil,
        upload: GeneratedVoyageTransport.FileUpload? = nil,
        _ operation: (Client) async throws -> Result
    ) async throws -> Result {
        let client = Client(
            serverURL: baseURL,
            configuration: .init(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: GeneratedVoyageTransport(transport: transport, bearer: bearer, fileUpload: upload)
        )
        do {
            return try await operation(client)
        } catch let error as ClientError {
            // The outbox classifies the HTTP status and transport error, including
            // failures that have no JSON body (offline, 503, or a background upload).
            throw error.underlyingError
        }
    }
}

/// Adapts generated operations to the iPhone's foreground and file-backed sessions.
@MainActor
private struct GeneratedVoyageTransport: ClientTransport {
    struct FileUpload {
        let file: URL
        let key: VoyageUploadKey
    }

    let transport: any VoyageTransport
    let bearer: String?
    let fileUpload: FileUpload?

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let path = request.path else { throw VoyageAPIError.invalidResponse }
        var absolute = HTTPRequest(method: request.method, url: baseURL.appending(path: path))
        absolute.headerFields = request.headerFields
        if let bearer { absolute.headerFields[.authorization] = "Bearer " + bearer }
        guard var request = URLRequest(httpRequest: absolute) else { throw VoyageAPIError.invalidResponse }

        let data: Data
        let response: HTTPURLResponse
        if let fileUpload {
            // The background URLSession reads the frozen file directly.
            response = try await transport.upload(request, file: fileUpload.file, key: fileUpload.key)
            data = Data()
        } else {
            if let body { request.httpBody = try await Data(collecting: body, upTo: 64 * 1024) }
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
