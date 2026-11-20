import Foundation
import Observation

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

    /// Shown beside Sync sessions in every state, Private and unknown included: the value on
    /// screen may be out of date, because it can be changed on the website at any time.
    static let explanation =
        "New uploads use your account’s Visibility of new sessions. If it’s Unlisted or Public, they’re shared that way automatically, with no further step on this iPhone. Change it in Settings on madegood.app."
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

/// The last known "Visibility of new sessions" for one sign-in, and when it was checked.
///
/// The website can change the setting at any moment, so the value is always shown with its
/// check time and refreshed on the Account screen appearing, the app returning to the
/// foreground, and before Sync sessions is turned on (review of #133). Refreshes can
/// overlap; each one takes a generation number and only the latest may apply its result,
/// so an older response that arrives last never replaces a newer one.
@MainActor @Observable
final class NewSessionVisibilityTracker {
    /// The last value the server returned for `binding`; kept after a failed refresh, with
    /// its original `checkedAt`, so the screen shows how old it is.
    private(set) var value: NewSessionVisibility?
    private(set) var checkedAt: Date?
    /// True while the latest refresh is in flight.
    private(set) var isChecking = false
    /// True when the latest refresh failed (offline, server error, unknown value).
    private(set) var lastCheckFailed = false
    private(set) var binding: VoyageAccountBinding?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    /// Forgets everything (sign-out or another sign-in). In-flight refreshes no longer apply.
    func reset(for binding: VoyageAccountBinding?) {
        generation &+= 1
        pending = nil
        isChecking = false
        lastCheckFailed = false
        value = nil
        checkedAt = nil
        self.binding = binding
    }

    /// A value the server just returned some other way (the sign-in response carries it).
    /// It is as fresh as a refresh, so it also supersedes any refresh in flight.
    func seed(_ value: NewSessionVisibility, for binding: VoyageAccountBinding) {
        generation &+= 1
        pending = nil
        isChecking = false
        lastCheckFailed = false
        self.binding = binding
        self.value = value
        checkedAt = now()
    }

    /// Starts a refresh for `binding` and waits for it. A result is applied only if no newer
    /// refresh, seed or reset happened meanwhile.
    func refresh(
        for binding: VoyageAccountBinding,
        using fetch: @escaping @MainActor () async throws -> NewSessionVisibility
    ) async {
        if self.binding != binding { reset(for: binding) }
        generation &+= 1
        let mine = generation
        isChecking = true
        let task = Task { @MainActor [weak self] in
            let result: NewSessionVisibility?
            do { result = try await fetch() } catch { result = nil }
            guard let self, self.generation == mine, self.binding == binding else { return }
            self.pending = nil
            self.isChecking = false
            if let result {
                self.value = result
                self.checkedAt = self.now()
                self.lastCheckFailed = false
            } else {
                self.lastCheckFailed = true
            }
        }
        pending = task
        await task.value
    }

    /// Waits until no refresh is in flight, including ones started while waiting.
    func settled() async {
        while let pending { await pending.value }
    }

    /// Refreshes, then reports whether a value checked at or after this call is known for
    /// `binding`. Turning on Sync sessions waits for this, so no upload starts on a value the
    /// user hasn't seen since the website could have changed it.
    func refreshedValue(
        for binding: VoyageAccountBinding,
        using fetch: @escaping @MainActor () async throws -> NewSessionVisibility
    ) async -> NewSessionVisibility? {
        let started = now()
        await refresh(for: binding, using: fetch)
        await settled()
        guard self.binding == binding, let value, let checkedAt, checkedAt >= started else { return nil }
        return value
    }
}
