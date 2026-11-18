import Foundation

typealias LiveVoyageOwner = Components.Schemas.VoyageChangeShareResult
typealias LiveVoyagePreview = Components.Schemas.VoyageViewerState
typealias LiveVoyageBatch = Components.Schemas.VoyagePositionBatch
typealias LiveVoyageSample = LiveVoyageBatch.positionsPayloadPayload
typealias LiveVoyageCommand = Components.Schemas.VoyageShareCommand

extension LiveVoyagePreview {
    static var unavailable: Self { .case1(.init(status: .unavailable)) }
}

/// Use the combined account and generated client with the foreground transport.
@MainActor
final class LiveVoyageAPI {
    let account: VoyageAccount
    private let baseURL: URL
    private let api: VoyageAPI
    private let foreground: () -> Bool

    init?(baseURL: URL, account: VoyageAccount, transport: any VoyageTransport, foreground: @escaping () -> Bool) {
        guard baseURL.scheme == "http", baseURL.host() == "127.0.0.1",
            baseURL.user == nil, baseURL.password == nil, baseURL.path == "/api",
            baseURL.query == nil, baseURL.fragment == nil
        else { return nil }
        self.baseURL = baseURL
        self.account = account
        self.api = VoyageAPI(baseURL: baseURL, transport: transport)
        self.foreground = foreground
    }

    func ensureVoyage(_ voyage: VoyageSnapshot, id: UUID, binding: VoyageAccountBinding) async throws {
        do {
            _ = try await owner(id: id, binding: binding)
        } catch let error as VoyageAPIError where error.status == 404 {
            try await account.authorized(for: binding) { token in
                try checkForeground()
                try await api.putVoyage(voyage, id: id, bearer: token)
            }
        }
    }

    func owner(id: UUID, binding: VoyageAccountBinding) async throws -> LiveVoyageOwner {
        try await authorized(binding) { client in
            let result = try await client.getVoyageSharing(
                .init(path: .init(voyageId: id.uuidString.lowercased()))
            ).ok.body.json
            return LiveVoyageOwner(
                sharing: LiveVoyageOwner.sharingPayload(rawValue: result.sharing.rawValue) ?? .off,
                delayS: result.delayS, grantGeneration: result.grantGeneration, preview: result.preview
            )
        }
    }

    func change(_ command: LiveVoyageCommand, id: UUID, binding: VoyageAccountBinding) async throws -> LiveVoyageOwner {
        try await authorized(binding) { client in
            try await client.changeVoyageSharing(
                .init(path: .init(voyageId: id.uuidString.lowercased()), body: .json(command))
            ).ok.body.json
        }
    }

    func upload(
        _ samples: [LiveVoyageSample], generation: Int, id: UUID, binding: VoyageAccountBinding,
        shouldSend: @escaping () -> Bool
    ) async throws {
        let result = try await authorized(binding, shouldSend: shouldSend) { client in
            try await client.postVoyagePositions(
                .init(
                    path: .init(voyageId: id.uuidString.lowercased()),
                    body: .json(LiveVoyageBatch(grantGeneration: generation, positions: samples))
                )
            ).ok.body.json
        }
        let expected = Set(samples.map(\.sampleId))
        guard Set(result.receipts.map(\.sampleId)) == expected,
            result.receipts.count == expected.count,
            result.receipts.allSatisfy({ $0.receivedAtMs >= 0 })
        else { throw VoyageAPIError.invalidResponse }
    }

    func link(slug: String) -> URL? {
        guard slug.utf8.count == 43,
            slug.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            })
        else { return nil }
        return baseURL.deletingLastPathComponent().appending(path: "v/\(slug)")
    }

    private func checkForeground() throws {
        try Task.checkCancellation()
        guard foreground() else { throw CancellationError() }
    }

    private func authorized<Result>(
        _ binding: VoyageAccountBinding, shouldSend: @escaping () -> Bool = { true },
        _ operation: (Client) async throws -> Result
    ) async throws -> Result {
        var value: Result?
        try await account.authorized(for: binding) { token in
            try checkForeground()
            value = try await api.withForegroundClient(
                bearer: token,
                beforeSend: {
                    try self.checkForeground()
                    guard self.account.binding == binding, shouldSend() else { throw CancellationError() }
                }, operation)
        }
        try checkForeground()
        guard let value else { throw VoyageAPIError.invalidResponse }
        return value
    }
}
