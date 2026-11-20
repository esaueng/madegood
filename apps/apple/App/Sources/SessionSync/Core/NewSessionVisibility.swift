import Foundation

/// The account's "Visibility of new sessions" (`GET /me` `defaultVisibility`). The server
/// gives every new upload this visibility (web/src/server/lib/session-upload.ts), so turning
/// sync on with Unlisted or Public shares later sessions with no further step on the phone.
enum NewSessionVisibility: String, Codable, Sendable, CaseIterable {
    case `private`, unlisted, `public`

    /// The website's label (web/src/client/components/visibility.tsx).
    var label: String {
        switch self {
        case .private: "Private"
        case .unlisted: "Unlisted"
        case .public: "Public"
        }
    }

    /// What turning sync on means for new uploads, shown beside the Sync sessions switch.
    /// `nil` (not loaded yet, offline, or an older server) gets wording that is true for
    /// every setting.
    static func notice(for visibility: NewSessionVisibility?) -> String {
        let change = "Change it in Settings on madegood.app."
        switch visibility {
        case .private?:
            return "New uploads are private: only you can see them until you share one. \(change)"
        case .unlisted?:
            return
                "New uploads will be unlisted automatically: anyone with a session’s link can see it, with no further step on this iPhone. \(change)"
        case .public?:
            return
                "New uploads will be public automatically: anyone can see them, with no further step on this iPhone. \(change)"
        case nil:
            return
                "New uploads take your account’s Visibility of new sessions setting. If it is Unlisted or Public, they are shared that way automatically. Check or change it in Settings on madegood.app."
        }
    }
}

/// Reads the signed-in account's "Visibility of new sessions".
@MainActor
enum AccountVisibility {
    /// `GET /me` through `VoyageAccount.authorized`, so an expired token is refreshed once.
    /// Throws if the request fails, the sign-in changed, or the server sent no known value.
    static func fetch(account: VoyageAccount, api: SessionAPI) async throws -> NewSessionVisibility {
        guard let binding = account.binding else { throw VoyageAccountError.signInRequired }
        var result: NewSessionVisibility?
        try await account.authorized(for: binding) { token in
            result = try await api.newSessionVisibility(bearer: token)
        }
        guard let result else { throw VoyageAPIError.invalidResponse }
        return result
    }
}
