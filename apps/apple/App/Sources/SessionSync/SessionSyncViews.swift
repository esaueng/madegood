import AuthenticationServices
import SwiftUI

extension SessionSyncStatus {
    func title(wifiOnly: Bool) -> String {
        switch self {
        case .pending: "Waiting to upload"
        case .uploading: "Uploading"
        case .synced: "Synced"
        case .retrying(_, offline: true): wifiOnly ? "Waiting for Wi-Fi" : "Waiting for a connection"
        case .retrying: "Upload failed, retrying"
        case .failed(.conflict): "Belongs to another account"
        case .failed(.tooLarge): "Too large to upload"
        case .failed(.rejected): "Upload rejected"
        case .failed(.retriesExhausted): "Upload failed"
        case .failed(.deletedFromCloud): "Deleted from your account"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "icloud"
        case .uploading: "arrow.up.icloud"
        case .synced: "checkmark.icloud"
        case .retrying(_, offline: true): "icloud.slash"
        case .retrying, .failed: "exclamationmark.icloud"
        }
    }

    var isProblem: Bool {
        switch self {
        case .failed(.deletedFromCloud): false
        case .failed: true
        case .retrying(_, let offline): !offline
        default: false
        }
    }

    /// Retry is offered for anything waiting on a timer or stopped, except a session the
    /// user deleted from the account.
    var canRetry: Bool {
        switch self {
        case .failed(.deletedFromCloud): false
        case .failed, .retrying: true
        default: false
        }
    }
}

/// A compact cloud badge for a History row's sport icon; nothing while sync is off.
struct SessionSyncBadge: View {
    @Environment(SessionSync.self) private var sync: SessionSync?
    let sessionID: UUID?

    var body: some View {
        if let sync, let sessionID, let status = sync.status(for: sessionID) {
            Image(systemName: status.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .padding(3)
                .background(.background, in: .circle)
                .accessibilityLabel(status.title(wifiOnly: sync.wifiOnly))
                .accessibilityIdentifier("session.sync")
        }
    }
}

/// The session detail's sync row, with Retry for a failed upload.
struct SessionSyncDetailRow: View {
    @Environment(SessionSync.self) private var sync: SessionSync?
    let sessionID: UUID

    var body: some View {
        if let sync, let status = sync.status(for: sessionID) {
            LabeledContent {
                Text(status.title(wifiOnly: sync.wifiOnly))
                    .accessibilityIdentifier("sessionSync.status")
            } label: {
                Label("Account sync", systemImage: status.symbol)
                    .foregroundStyle(status.isProblem ? .orange : .primary)
            }
            if status.canRetry {
                Button("Retry Upload") { sync.retry(sessionID) }
                    .accessibilityIdentifier("sessionSync.retry")
            }
        }
    }
}

/// Settings: the MadeGood account and the session sync switches.
struct SessionSyncSection: View {
    @Environment(SessionSync.self) private var sync: SessionSync?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingDeletion = false

    var body: some View {
        Section {
            if let sync {
                content(sync)
            } else {
                Text("Account sync isn’t set up in this build.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sessionSync.unavailable")
            }
        } header: {
            Text("Account")
        } footer: {
            Text(
                "When sync is on, sessions recorded while you are signed in upload to your MadeGood account and take its Visibility of new sessions setting: Private, Unlisted or Public. Signing out turns sync off. Recordings stay on this iPhone."
            )
        }
        .disabled(busy)
        .task { await sync?.refreshNewSessionVisibility() }
        .onChange(of: sync?.isEnabled) { _, enabled in
            if enabled == true { Task { await sync?.refreshNewSessionVisibility() } }
        }
        .alert("Delete your MadeGood account?", isPresented: $confirmingDeletion) {
            Button("Delete Account", role: .destructive) {
                if let sync { deleteAccount(sync) }
            }
            .accessibilityIdentifier("sessionSync.confirmDelete")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deletionWarning)
        }
    }

    static let deletionWarning =
        "This deletes every session you have uploaded, your privacy zones, your settings and your sign-in from MadeGood’s servers. Recordings on this iPhone and your Apple Watch stay on your devices, and workouts in Apple Health are not affected. This can’t be undone."

    @ViewBuilder
    private func content(_ sync: SessionSync) -> some View {
        @Bindable var sync = sync
        if sync.account.binding != nil {
            Label("Signed in", systemImage: "person.crop.circle.badge.checkmark")
                .accessibilityIdentifier("sessionSync.signedIn")
            Toggle("Sync sessions", isOn: $sync.isEnabled)
                .accessibilityIdentifier("sessionSync.enabled")
            // Shown before and after the switch is turned on: an Unlisted or Public account
            // default shares every new upload automatically (review of #133).
            LabeledContent(
                "Visibility of new sessions", value: sync.newSessionVisibility?.label ?? "Unknown"
            )
            .accessibilityIdentifier("sessionSync.visibility")
            Text(NewSessionVisibility.notice(for: sync.newSessionVisibility))
                .font(.footnote)
                .foregroundStyle(sync.newSessionVisibility == .private ? .secondary : .primary)
                .accessibilityIdentifier("sessionSync.visibilityNotice")
            if sync.isEnabled {
                Toggle("Upload on Wi-Fi only", isOn: $sync.wifiOnly)
                    .accessibilityIdentifier("sessionSync.wifiOnly")
                summary(sync)
                if !sync.earlierSessions.isEmpty {
                    let count = sync.earlierSessions.count
                    Button("Upload \(count) Earlier \(count == 1 ? "Session" : "Sessions")") {
                        sync.uploadEarlierSessions()
                    }
                    .accessibilityIdentifier("sessionSync.uploadEarlier")
                    Text("Recorded on this iPhone before you signed in. They upload only if you choose to.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Sign Out", role: .destructive) {
                perform(failure: "Couldn’t clear the saved sign-in. Try again.") { try await sync.signOut() }
            }
            .accessibilityIdentifier("sessionSync.signOut")
            Button("Delete Account…", role: .destructive) { confirmingDeletion = true }
                .accessibilityIdentifier("sessionSync.deleteAccount")
        } else {
            if sync.isDemo {
                Button("Sign In with Synthetic Account") {
                    perform(failure: "Couldn’t sign in.") {
                        try await sync.account.signIn(identityToken: "synthetic-identity", displayName: nil)
                    }
                }
                .accessibilityIdentifier("sessionSync.demoSignIn")
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handleAppleSignIn(result, sync: sync)
                }
                .frame(height: 44)
                .accessibilityIdentifier("sessionSync.appleSignIn")
            }
            if sync.account.storageUnavailable {
                Text("The saved sign-in is unavailable.").foregroundStyle(.secondary)
                Button("Clear Saved Sign-In") {
                    perform(failure: "Couldn’t clear the saved sign-in. Try again.") { try await sync.signOut() }
                }
            }
        }
        if busy { ProgressView() }
        if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("sessionSync.message") }
    }

    @ViewBuilder
    private func summary(_ sync: SessionSync) -> some View {
        let statuses = Array(sync.outbox.statuses.values)
        let synced = statuses.filter { $0 == .synced }.count
        let waiting = statuses.count - synced - statuses.filter(\.isProblem).count
        let problems = statuses.filter(\.isProblem).count
        LabeledContent("Synced", value: synced.formatted())
            .accessibilityIdentifier("sessionSync.syncedCount")
        if waiting > 0 || sync.preparing {
            LabeledContent("Waiting to upload", value: waiting.formatted())
        }
        if problems > 0 {
            LabeledContent("Need attention", value: problems.formatted())
                .accessibilityIdentifier("sessionSync.problemCount")
        }
        if sync.queueUnavailable {
            Text("The upload queue is unavailable.").foregroundStyle(.secondary)
        }
        if statuses.contains(where: \.canRetry) || sync.queueUnavailable {
            Button("Retry Failed Uploads") { sync.retry() }
                .accessibilityIdentifier("sessionSync.retryAll")
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>, sync: SessionSync) {
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
                try await sync.account.signIn(identityToken: token, displayName: name?.isEmpty == true ? nil : name)
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            message = nil
        } catch {
            message = "Couldn’t sign in with Apple. Try again."
        }
    }

    private func deleteAccount(_ sync: SessionSync) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await sync.deleteAccount()
                message = "Your account was deleted. Recordings stay on this iPhone."
            } catch VoyageAccountError.signInRequired {
                message = "Your sign-in expired. Sign in again, then delete your account."
            } catch is AccountDeletedSignOutFailed {
                message = "Your account was deleted, but the saved sign-in couldn’t be cleared. Clear it below."
            } catch {
                message = "Couldn’t delete your account. Check your connection and try again."
            }
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
