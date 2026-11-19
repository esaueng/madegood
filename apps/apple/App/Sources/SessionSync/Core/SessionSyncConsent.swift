import Foundation

/// Which recordings an account may receive. Sync never backfills sessions to an account
/// that did not consent to them:
/// - "Sync sessions" is on only for the sign-in that turned it on; a sign-out or another
///   sign-in turns it off.
/// - A recording started while an account was signed in belongs to that account. Only
///   its own recordings upload automatically; another account's never do.
/// - A recording made while nobody was signed in uploads only after the user chooses
///   "Upload earlier sessions" for the account now signed in.
struct SessionSyncConsent: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let accountID: String
        let signInID: UUID
        let start: Date
        var end: Date?

        func contains(_ date: Date) -> Bool {
            start <= date && end.map { date < $0 } ?? true
        }
    }

    enum Eligibility: Equatable, Sendable {
        /// Recorded while this account was signed in, or chosen explicitly.
        case automatic
        /// Recorded while nobody was signed in: needs an explicit choice.
        case earlier
        /// Recorded while another account was signed in: never uploaded to this one.
        case otherAccount
    }

    private(set) var windows: [Window] = []
    /// The sign-in that turned sync on.
    private(set) var enabledSignIn: UUID?
    /// Earlier sessions each account chose to upload, by account ID.
    private(set) var adopted: [String: Set<UUID>] = [:]

    /// Records a sign-in, closing any other open window. Repeating it does nothing.
    mutating func signedIn(_ binding: VoyageAccountBinding, at date: Date) {
        if windows.contains(where: { $0.signInID == binding.signInID }) { return }
        close(at: date)
        windows.append(Window(accountID: binding.accountID, signInID: binding.signInID, start: date))
        if enabledSignIn != binding.signInID { enabledSignIn = nil }
    }

    /// Records a sign-out (or a lost sign-in) and turns sync off.
    mutating func signedOut(at date: Date) {
        close(at: date)
        enabledSignIn = nil
    }

    func isEnabled(for binding: VoyageAccountBinding?) -> Bool {
        binding.map { enabledSignIn == $0.signInID } ?? false
    }

    mutating func setEnabled(_ enabled: Bool, for binding: VoyageAccountBinding) {
        enabledSignIn = enabled ? binding.signInID : nil
    }

    func eligibility(sessionID: UUID, startedAt: Date, for binding: VoyageAccountBinding) -> Eligibility {
        if let window = windows.last(where: { $0.contains(startedAt) }) {
            return window.accountID == binding.accountID ? .automatic : .otherAccount
        }
        // Adopting can only reach sessions nobody was signed in for.
        return adopted[binding.accountID]?.contains(sessionID) == true ? .automatic : .earlier
    }

    /// The user chose to upload these earlier sessions to this account.
    mutating func adopt(_ ids: some Sequence<UUID>, for binding: VoyageAccountBinding) {
        adopted[binding.accountID, default: []].formUnion(ids)
    }

    private mutating func close(at date: Date) {
        for index in windows.indices where windows[index].end == nil {
            windows[index].end = max(date, windows[index].start)
        }
    }
}
