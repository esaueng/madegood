import AuthenticationServices
import SwiftUI

struct PrivateVoyageAccountSection: View {
    @Environment(PrivateVoyageSync.self) private var sync
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Section {
            if sync.account.binding != nil {
                Text("Signed in")
                    .accessibilityIdentifier("voyageSync.signedIn")
                summaryRows
                Button("Sign Out") {
                    perform(failure: "Couldn’t clear the saved sign-in. Try again.") {
                        try await sync.signOut()
                    }
                }
                .accessibilityIdentifier("voyageSync.signOut")
            } else {
                signIn
                if sync.account.storageUnavailable {
                    Text("The saved sign-in is unavailable.")
                        .foregroundStyle(.secondary)
                    Button("Clear Saved Sign-In") {
                        perform(failure: "Couldn’t clear the saved sign-in. Try again.") {
                            try await sync.signOut()
                        }
                    }
                }
            }
            if busy { ProgressView() }
            if let message { Text(message).foregroundStyle(.secondary) }
        } header: {
            Text("Private Voyage Sync")
        } footer: {
            Text("Synced voyages and tracks are visible only to your account. Recordings stay on this iPhone.")
        }
        .disabled(busy)
    }

    @ViewBuilder
    private var signIn: some View {
        if sync.isDemo {
            Button("Sign In with Synthetic Account") {
                perform(failure: "Couldn’t sign in.") {
                    try await sync.account.signIn(identityToken: "synthetic-identity", displayName: nil)
                }
            }
            .accessibilityIdentifier("voyageSync.demoSignIn")
        } else {
            AppleSignInRow(onCompletion: handleAppleSignIn)
        }
    }

    @ViewBuilder
    private var summaryRows: some View {
        let statuses = sync.outbox.statuses.values
        let synced = statuses.filter { $0 == .synced }.count
        let queued = statuses.filter { $0 == .queued }.count
        let offline = statuses.filter { $0 == .waitingForConnection }.count
        let failures = statuses.filter { if case .retryableFailure = $0 { true } else { false } }.count
        let conflicts = statuses.filter { if case .needsAttention(_, 409) = $0 { true } else { false } }.count
        let rejected = statuses.filter { if case .needsAttention = $0 { true } else { false } }.count - conflicts
        if synced > 0 {
            LabeledContent("Synced", value: synced.formatted()).accessibilityIdentifier("voyageSync.synced")
        }
        if queued > 0 { LabeledContent("Queued", value: queued.formatted()) }
        if statuses.contains(where: { if case .syncing = $0 { true } else { false } }) { Text("Syncing") }
        if offline > 0 { LabeledContent("Waiting for connection", value: offline.formatted()) }
        if failures > 0 { LabeledContent("Retryable failure", value: failures.formatted()) }
        if conflicts > 0 { LabeledContent("Sync conflict", value: conflicts.formatted()) }
        if rejected > 0 { LabeledContent("Needs attention", value: rejected.formatted()) }
        if sync.outboxUnavailable { Text("The sync queue is unavailable.").foregroundStyle(.secondary) }
        if offline + failures > 0 || sync.outboxUnavailable {
            Button("Retry Sync", action: sync.retryNow)
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identity = credential.identityToken,
                let token = String(data: identity, encoding: .utf8), !token.isEmpty
            else {
                message = "Apple didn’t provide a sign-in token. Try again."
                return
            }
            let name = credential.fullName?.formatted()
            perform(failure: "Couldn’t sign in to MadeGood. Try again.") {
                try await sync.account.signIn(identityToken: token, displayName: name)
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            message = nil
        } catch {
            message = "Couldn’t sign in with Apple. Try again."
        }
    }

    private func perform(failure: String, operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await operation() } catch { message = failure }
        }
    }
}

private struct AppleSignInRow: View {
    @Environment(\.colorScheme) private var appearance
    let onCompletion: (Result<ASAuthorization, Error>) -> Void

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName]
        } onCompletion: { result in
            onCompletion(result)
        }
        .signInWithAppleButtonStyle(appearance == .dark ? .white : .black)
        .frame(height: 44)
        .accessibilityIdentifier("voyageSync.appleSignIn")
    }
}
