import Foundation
import Observation

struct VoyageAccountBinding: Codable, Equatable, Sendable {
    let accountID: String
    // A new sign-in is a new authorization, even for the same server account.
    let signInID: UUID
}

struct VoyageCredentials: Codable, Sendable {
    let binding: VoyageAccountBinding
    let tokens: VoyageTokenPair
}

@MainActor
protocol VoyageCredentialStore {
    func load() throws -> VoyageCredentials?
    func save(_ credentials: VoyageCredentials?) throws
}

enum VoyageAccountError: Error, Equatable {
    case signInRequired
    case accountChanged
    case alreadySignedIn
    case invalidCredentials
}

@MainActor @Observable
final class VoyageAccount {
    private(set) var binding: VoyageAccountBinding?
    private(set) var storageUnavailable = false
    private let store: any VoyageCredentialStore
    private let api: VoyageAPI
    @ObservationIgnored private var credentials: VoyageCredentials?
    @ObservationIgnored private var refreshTask: Task<Void, Error>?
    @ObservationIgnored private var generation = UUID()

    init(store: any VoyageCredentialStore, api: VoyageAPI) {
        self.store = store
        self.api = api
        do {
            credentials = try store.load()
            binding = credentials?.binding
        } catch {
            storageUnavailable = true
        }
    }

    /// Returns the signed-in account as the server sent it, so a caller can use its settings
    /// without another request. The binding is already set when this returns.
    @discardableResult
    func signIn(identityToken: String, displayName: String?) async throws -> Components.Schemas.User {
        guard binding == nil else { throw VoyageAccountError.alreadySignedIn }
        let attempt = UUID()
        generation = attempt
        let response = try await api.signIn(identityToken: identityToken, displayName: displayName)
        try Task.checkCancellation()
        guard generation == attempt else { throw VoyageAccountError.accountChanged }
        guard !response.user.id.isEmpty else { throw VoyageAccountError.invalidCredentials }
        try persist(
            VoyageCredentials(
                binding: VoyageAccountBinding(accountID: response.user.id, signInID: UUID()),
                tokens: VoyageTokenPair(accessToken: response.accessToken, refreshToken: response.refreshToken)
            ))
        return response.user
    }

    func signOut() throws {
        // Invalidate in-flight work before touching storage. A failed keychain
        // mutation remains visible so the user can retry clearing the credential.
        invalidate()
        try persist(nil)
    }

    func authorized(
        for expected: VoyageAccountBinding,
        operation: (String) async throws -> Void
    ) async throws {
        let sent = try await accessToken(for: expected)
        try Task.checkCancellation()
        try require(expected)
        do {
            try await operation(sent)
        } catch let error as VoyageAPIError where error.status == 401 {
            try Task.checkCancellation()
            try await refresh(rejectedToken: sent, for: expected)
            let replacement = try await accessToken(for: expected)
            try Task.checkCancellation()
            try require(expected)
            do {
                try await operation(replacement)
            } catch let error as VoyageAPIError where error.status == 401 {
                // A newer refresh may already have replaced this token.
                if binding == expected, credentials?.tokens.accessToken == replacement, refreshTask == nil {
                    try signOut()
                    throw VoyageAccountError.signInRequired
                }
                throw error
            }
        }
        try Task.checkCancellation()
        try require(expected)
    }

    private func require(_ expected: VoyageAccountBinding) throws {
        guard binding == expected else { throw VoyageAccountError.accountChanged }
    }

    private func accessToken(for expected: VoyageAccountBinding) async throws -> String {
        if let refreshTask { try await refreshTask.value }
        try Task.checkCancellation()
        try require(expected)
        guard let credentials else { throw VoyageAccountError.signInRequired }
        return credentials.tokens.accessToken
    }

    private func refresh(rejectedToken: String, for expected: VoyageAccountBinding) async throws {
        try require(expected)
        if let refreshTask {
            try await refreshTask.value
            return
        }
        guard let current = credentials else { throw VoyageAccountError.signInRequired }
        guard current.tokens.accessToken == rejectedToken else { return }

        // Remove the rotating token before sending it. If the response is lost or
        // the process stops mid-refresh, a restart cannot reuse that token.
        do {
            try store.save(nil)
        } catch {
            storageUnavailable = true
            throw error
        }
        let attempt = generation
        let task = Task {
            defer {
                if generation == attempt { refreshTask = nil }
            }
            do {
                let tokens = try await api.refresh(current.tokens.refreshToken)
                guard generation == attempt else { throw VoyageAccountError.accountChanged }
                try persist(VoyageCredentials(binding: expected, tokens: tokens))
            } catch {
                guard generation == attempt else { throw VoyageAccountError.accountChanged }
                if case .http(429, "rate_limited"?, _) = error as? VoyageAPIError {
                    // The Worker rate-limits before rotating the token. Restore it and
                    // let the caller retry with the server's delay.
                    try persist(current)
                    throw error
                }
                invalidate()
                throw VoyageAccountError.signInRequired
            }
        }
        refreshTask = task
        try await task.value
    }

    private func persist(_ value: VoyageCredentials?) throws {
        if let value {
            guard !value.tokens.accessToken.isEmpty, !value.tokens.refreshToken.isEmpty else {
                throw VoyageAccountError.invalidCredentials
            }
        }
        do {
            try store.save(value)
        } catch {
            storageUnavailable = true
            throw error
        }
        storageUnavailable = false
        credentials = value
        binding = value?.binding
    }

    private func invalidate() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        binding = nil
    }
}
