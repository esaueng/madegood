import SwiftUI
import WaterKit

/// Settings → Account → Sharing: the account-wide sharing switch and every session others
/// can see, each with Make Private. Turning sharing off makes every session private on the
/// server at once and keeps new uploads private until it is turned back on.
struct SharingSettingsView: View {
    let sync: SessionSync

    @State private var enabled: Bool?
    @State private var sessions: [SharedSession] = []
    @State private var loading = false
    @State private var busy: Set<String> = []
    @State private var changingSwitch = false
    @State private var confirmingOff = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Toggle("Allow Sharing", isOn: switchBinding)
                    .disabled(enabled == nil || changingSwitch)
                    .accessibilityIdentifier("sharing.enabled")
            } footer: {
                Text(Self.switchExplanation)
            }

            Section {
                if loading && sessions.isEmpty {
                    ProgressView()
                } else if sessions.isEmpty {
                    Text("Nothing is shared. Every session is private.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sharing.none")
                } else {
                    ForEach(sessions) { session in
                        row(session)
                    }
                }
            } header: {
                Text("Shared Sessions")
            } footer: {
                Text("Unlisted sessions open for anyone with the link. Public ones also appear on your profile. To share a session, open it on madegood.app.")
            }

            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sharing.message")
            }
        }
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Turn off sharing?", isPresented: $confirmingOff, titleVisibility: .visible
        ) {
            Button("Turn Off Sharing", role: .destructive) { setEnabled(false) }
                .accessibilityIdentifier("sharing.confirmOff")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(offWarning)
        }
    }

    static let switchExplanation =
        "When sharing is off, every session in your MadeGood account is private, links you shared stop working, and new uploads stay private until you turn it back on. Turning it on shares nothing by itself."

    private var offWarning: String {
        let count = sessions.count
        if count == 0 { return "New uploads will stay private until you turn sharing back on." }
        let noun = count == 1 ? "session becomes" : "sessions become"
        return "\(count) shared \(noun) private right away, and their links stop working."
    }

    private var switchBinding: Binding<Bool> {
        Binding(
            get: { enabled ?? false },
            set: { newValue in
                if newValue { setEnabled(true) } else { confirmingOff = true }
            })
    }

    @ViewBuilder
    private func row(_ session: SharedSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(session))
                    .lineLimit(1)
                Label(detail(session), systemImage: session.visibility == "public" ? "globe" : "link")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Make Private") { makePrivate(session) }
                .buttonStyle(.borderless)
                .disabled(busy.contains(session.id))
                .accessibilityIdentifier("sharing.makePrivate")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharing.session")
    }

    private func title(_ session: SharedSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        return Sport(rawValue: session.sport)?.displayName ?? "Session"
    }

    private func detail(_ session: SharedSession) -> String {
        let kind = session.visibility == "public" ? "Public" : "Unlisted"
        guard let date = Self.parse(session.startedAt) else { return kind }
        return "\(kind) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func parse(_ iso: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso))
            ?? (try? Date.ISO8601FormatStyle().parse(iso))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (state, shared) = try await sync.withAccount { api, token in
                let state = try await api.sharingEnabled(bearer: token)
                var all: [SharedSession] = []
                var cursor: String?
                // At most 20 pages of 100; the website lists the rest.
                for _ in 0..<20 {
                    let page = try await api.sharedSessions(cursor: cursor, bearer: token)
                    all += page.sessions
                    guard let next = page.nextCursor else { break }
                    cursor = next
                }
                return (state, all)
            }
            enabled = state
            sessions = shared
            message = nil
        } catch {
            message = failure(error, doing: "load your sharing settings")
        }
    }

    private func setEnabled(_ value: Bool) {
        changingSwitch = true
        message = nil
        Task {
            defer { changingSwitch = false }
            do {
                enabled = try await sync.withAccount { api, token in
                    try await api.setSharingEnabled(value, bearer: token)
                }
                if value == false { sessions = [] }
                await load()
            } catch {
                message = failure(error, doing: value ? "turn sharing on" : "turn sharing off")
            }
        }
    }

    private func makePrivate(_ session: SharedSession) {
        busy.insert(session.id)
        message = nil
        Task {
            defer { busy.remove(session.id) }
            do {
                try await sync.withAccount { api, token in
                    try await api.makePrivate(sessionID: session.id, bearer: token)
                }
                sessions.removeAll { $0.id == session.id }
            } catch let error as VoyageAPIError where error.status == 404 {
                // Already gone from the account: nothing left to share.
                sessions.removeAll { $0.id == session.id }
            } catch {
                message = failure(error, doing: "make it private")
            }
        }
    }

    private func failure(_ error: any Error, doing action: String) -> String {
        if case VoyageAccountError.signInRequired = error { return "Your sign-in expired. Sign in again." }
        return "Couldn’t \(action). Check your connection and try again."
    }
}
