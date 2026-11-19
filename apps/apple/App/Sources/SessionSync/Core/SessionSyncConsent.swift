import Foundation
import Observation

/// Which recordings an account may receive. Sync never backfills sessions to an account
/// that did not consent to them:
/// - "Sync sessions" is on only for the sign-in that turned it on; a sign-out or another
///   sign-in turns it off.
/// - Each sign-in's window is written before its credentials are saved (`signedIn` is
///   called from the credential store), so credentials can never exist without a
///   persisted window. A sign-in without one gets nothing automatically.
/// - A recording uploads automatically only when its whole time range, widened by
///   `clockMargin` for clock skew (watch recordings), lies inside one window of this
///   account. One that touches a boundary or a gap with no window needs an explicit
///   choice ("Upload earlier sessions"). One whose widened range touches another
///   account's window is never offered to a different account than the one signed in
///   when it started: only that account may upload it, and only explicitly.
/// - A session the user deleted from the account is never queued for it again.
struct SessionSyncConsent: Codable, Equatable, Sendable {
    /// Widens each recording's time range on both sides before matching it to a window.
    static let clockMargin: TimeInterval = 600

    struct Window: Codable, Equatable, Sendable {
        let accountID: String
        let signInID: UUID
        let start: Date
        var end: Date?

        func contains(_ range: ClosedRange<Date>) -> Bool {
            start <= range.lowerBound && end.map { range.upperBound < $0 } ?? true
        }

        func contains(_ date: Date) -> Bool { contains(date...date) }

        func overlaps(_ range: ClosedRange<Date>) -> Bool {
            start <= range.upperBound && end.map { range.lowerBound < $0 } ?? true
        }
    }

    enum Eligibility: Equatable, Sendable {
        /// Recorded well inside this account's sign-in, or chosen explicitly.
        case automatic
        /// Not attributable to this account: needs an explicit choice.
        case earlier
        /// Recorded entirely while another account was signed in: never for this one.
        case otherAccount
        /// Deleted from this account by the user: never uploaded again.
        case deletedFromCloud
    }

    private(set) var windows: [Window] = []
    /// The sign-in that turned sync on.
    private(set) var enabledSignIn: UUID?
    /// Earlier sessions each account chose to upload, by account ID.
    private(set) var adopted: [String: Set<UUID>] = [:]
    /// Sessions each account deleted on the server (410), by account ID.
    private(set) var deletedFromCloud: [String: Set<UUID>] = [:]

    /// Records a sign-in, closing any other open window. Repeating it does nothing.
    mutating func signedIn(_ binding: VoyageAccountBinding, at date: Date) {
        if windows.contains(where: { $0.signInID == binding.signInID && $0.end == nil }) { return }
        close(at: date)
        windows.append(Window(accountID: binding.accountID, signInID: binding.signInID, start: date))
        if enabledSignIn != binding.signInID { enabledSignIn = nil }
    }

    /// Records a sign-out (or a lost sign-in) and turns sync off.
    mutating func signedOut(at date: Date) {
        close(at: date)
        enabledSignIn = nil
    }

    func hasWindow(for binding: VoyageAccountBinding) -> Bool {
        windows.contains { $0.signInID == binding.signInID }
    }

    func isEnabled(for binding: VoyageAccountBinding?) -> Bool {
        guard let binding, hasWindow(for: binding) else { return false }
        return enabledSignIn == binding.signInID
    }

    mutating func setEnabled(_ enabled: Bool, for binding: VoyageAccountBinding) {
        enabledSignIn = enabled && hasWindow(for: binding) ? binding.signInID : nil
    }

    func eligibility(
        sessionID: UUID, startedAt: Date, endedAt: Date, for binding: VoyageAccountBinding
    ) -> Eligibility {
        if deletedFromCloud[binding.accountID]?.contains(sessionID) == true { return .deletedFromCloud }
        let recorded = startedAt...max(startedAt, endedAt)
        let widened =
            recorded.lowerBound.addingTimeInterval(-Self.clockMargin)...recorded.upperBound.addingTimeInterval(
                Self.clockMargin)
        let mine = { (window: Window) in window.accountID == binding.accountID }
        if windows.contains(where: { !mine($0) && $0.overlaps(widened) }) {
            // Near another account's sign-in: ambiguous, so it belongs to whoever was signed
            // in when it started, and even then needs an explicit choice.
            guard windows.contains(where: { mine($0) && $0.contains(startedAt) }) else { return .otherAccount }
            return adopted[binding.accountID]?.contains(sessionID) == true ? .automatic : .earlier
        }
        if hasWindow(for: binding),
            windows.contains(where: { $0.accountID == binding.accountID && $0.contains(widened) })
        {
            return .automatic
        }
        return adopted[binding.accountID]?.contains(sessionID) == true ? .automatic : .earlier
    }

    /// The user chose to upload these earlier sessions to this account.
    mutating func adopt(_ ids: some Sequence<UUID>, for binding: VoyageAccountBinding) {
        adopted[binding.accountID, default: []].formUnion(ids)
    }

    mutating func markDeleted(_ ids: Set<UUID>, for binding: VoyageAccountBinding) {
        guard !ids.isEmpty else { return }
        deletedFromCloud[binding.accountID, default: []].formUnion(ids)
        adopted[binding.accountID]?.subtract(ids)
    }

    /// The account was deleted on the server: forgets every consent decision for it (its
    /// sign-in windows, adopted and deleted sessions) and turns sync off. Recordings made
    /// while it was signed in then count as earlier sessions for any later account, which
    /// uploads them only by explicit choice.
    mutating func forget(accountID: String) {
        windows.removeAll { $0.accountID == accountID }
        adopted[accountID] = nil
        deletedFromCloud[accountID] = nil
        if let enabledSignIn, !windows.contains(where: { $0.signInID == enabledSignIn }) {
            self.enabledSignIn = nil
        }
    }

    private mutating func close(at date: Date) {
        for index in windows.indices where windows[index].end == nil {
            windows[index].end = max(date, windows[index].start)
        }
    }
}

/// Saves credentials only after the consent record for them is durable: the sign-in's
/// window is written first (write-ahead). A sign-out closes the window before the
/// credentials are removed. The rotating-token removal during a refresh (credentials
/// cleared while still signed in) is not a sign-out and leaves the window open.
@MainActor
final class ConsentRecordingStore: VoyageCredentialStore {
    private let base: any VoyageCredentialStore
    var willSave: (VoyageCredentials?) throws -> Void = { _ in }

    init(_ base: any VoyageCredentialStore) { self.base = base }

    func load() throws -> VoyageCredentials? { try base.load() }

    func save(_ credentials: VoyageCredentials?) throws {
        try willSave(credentials)
        try base.save(credentials)
    }
}

/// The durable consent record: a JSON file written atomically before any change is
/// visible, so the record on disk is never behind what the app acted on.
@MainActor @Observable
final class SessionConsentLedger {
    private(set) var consent: SessionSyncConsent
    private let url: URL

    init(url: URL) {
        self.url = url
        consent =
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SessionSyncConsent.self, from: $0) }
            ?? SessionSyncConsent()
    }

    func update(_ change: (inout SessionSyncConsent) -> Void) throws {
        var updated = consent
        change(&updated)
        guard updated != consent else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            try JSONEncoder().encode(updated).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        #endif
        consent = updated
    }

    /// Wires `store` so the consent record changes before the credentials do. `isSignedIn`
    /// tells a sign-out (the account already let go of its sign-in) from a refresh.
    func guardCredentials(_ store: ConsentRecordingStore, now: @escaping () -> Date, isSignedIn: @escaping () -> Bool) {
        store.willSave = { [weak self] credentials in
            guard let self else { return }
            if let credentials {
                try update { $0.signedIn(credentials.binding, at: now()) }
            } else if !isSignedIn() {
                try update { $0.signedOut(at: now()) }
            }
        }
    }
}
