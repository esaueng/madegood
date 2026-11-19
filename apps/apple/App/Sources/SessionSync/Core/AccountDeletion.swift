import Foundation

/// The account was deleted on the server, but the saved sign-in could not be cleared from
/// the keychain. Its tokens no longer work; clearing it again finishes the sign-out.
struct AccountDeletedSignOutFailed: Error {
    let underlying: any Error
}

/// Settings → Account → Delete Account (App Store guideline 5.1.1(v)).
@MainActor
enum AccountDeletion {
    /// Deletes the signed-in account on the server (`DELETE /me`: sessions, tracks, privacy
    /// zones, settings and sign-ins), then signs out on this device and forgets the account's
    /// sync consent. Recordings on the device are never touched.
    ///
    /// On a server or network failure nothing changes locally and the error is thrown. A
    /// refused token is refreshed once by `VoyageAccount.authorized`; if that fails the
    /// sign-in is dropped and `VoyageAccountError.signInRequired` is thrown.
    @discardableResult
    static func delete(
        account: VoyageAccount, api: SessionAPI, ledger: SessionConsentLedger
    ) async throws -> VoyageAccountBinding {
        guard let binding = account.binding else { throw VoyageAccountError.signInRequired }
        try await account.authorized(for: binding) { token in
            try await api.deleteAccount(accountID: binding.accountID, bearer: token)
        }
        var failure: (any Error)?
        do {
            try account.signOut()
        } catch {
            failure = error
        }
        do {
            try ledger.update { $0.forget(accountID: binding.accountID) }
        } catch {
            failure = failure ?? error
        }
        if let failure { throw AccountDeletedSignOutFailed(underlying: failure) }
        return binding
    }
}
