import Foundation
import SwiftUI
import UIKit
import WaterKit

/// Owned alongside the phone account, with storage separate from private leg sync.
@MainActor
final class LiveVoyageSharing {
    private let api: LiveVoyageAPI
    private let root: URL
    private var sessions: [UUID: LiveVoyageShare] = [:]
    private var lastBinding: VoyageAccountBinding?
    var binding: VoyageAccountBinding? { api.account.binding }

    init?(apiRoot: URL, root: URL, account: VoyageAccount, transport: any VoyageTransport, isDemo: Bool) {
        #if DEBUG && targetEnvironment(simulator)
            guard isDemo, ProcessInfo.processInfo.arguments.contains("-localVoyageSharing"),
                let api = LiveVoyageAPI(
                    baseURL: apiRoot, account: account, transport: transport,
                    foreground: { UIApplication.shared.applicationState == .active })
            else { return nil }
            self.api = api
            self.root = root
            self.lastBinding = account.binding
        #else
            return nil
        #endif
    }

    func accountDidChange() {
        guard binding != lastBinding else { return }
        for session in sessions.values { session.invalidate() }
        sessions.removeAll()
        // Journals for voyages not yet opened still carry their previous sign-in binding.
        lastBinding = binding
    }

    func session(for id: UUID) -> LiveVoyageShare? {
        accountDidChange()
        guard let binding else { return nil }
        if let session = sessions[id] { return session }
        let session = LiveVoyageShare(
            id: id, binding: binding, api: api,
            file: root.appending(path: "\(id.uuidString.lowercased()).json"),
            now: { Int((Date.now.timeIntervalSince1970 * 1_000).rounded(.down)) }
        )
        sessions[id] = session
        return session
    }

    func savedPosition(voyageID: UUID, legID: UUID, position: VoyagePosition, gapBefore: Bool) {
        // Opening the voyage restores its permit. A recorder event by itself never opts in.
        sessions[voyageID]?.capture(
            legID: legID, capturedAt: position.timestamp, latitude: position.latitude,
            longitude: position.longitude, gapBefore: gapBefore
        )
    }
}

struct LiveVoyageSharingSection: View {
    let service: LiveVoyageSharing
    let voyage: Voyage
    @State private var session: LiveVoyageShare?

    var body: some View {
        Group {
            if let session, session.isBound, let firstLeg = voyage.legs.first {
                LiveVoyageControls(
                    session: session,
                    voyage: VoyageSnapshot(
                        title: voyage.name, startedAt: Date(timeIntervalSince1970: firstLeg.startedAt))
                )
                .id(session.binding.signInID)
            } else {
                Section("Live Sharing") {
                    if service.binding == nil {
                        Text("Sign in to the local test account to share.")
                    } else {
                        ProgressView("Checking sharing status")
                    }
                }
            }
        }
        .task(id: service.binding) {
            session = service.session(for: voyage.id)
        }
    }
}

private struct LiveVoyageControls: View {
    let session: LiveVoyageShare
    let voyage: VoyageSnapshot
    @Environment(\.scenePhase) private var phase
    @State private var delay = 3_600
    @State private var duration = 86_400
    @State private var confirming = false
    @State private var replacing = false

    var body: some View {
        Section {
            if let state = session.sharing {
                LabeledContent("Sharing", value: state == .on ? "On" : state == .paused ? "Paused on server" : "Off")
            } else {
                Text("Checking sharing status")
                    .foregroundStyle(.secondary)
            }
            Picker("Position delay", selection: $delay) {
                Text("No delay").tag(0)
                Text("15 minutes").tag(900)
                Text("1 hour").tag(3_600)
                Text("6 hours").tag(21_600)
                Text("24 hours").tag(86_400)
                if let current = session.serverDelay,
                    ![0, 900, 3_600, 21_600, 86_400].contains(current)
                {
                    Text(Duration.seconds(current).formatted(.units(allowed: [.hours, .minutes, .seconds]))).tag(
                        current)
                }
            }
            .accessibilityIdentifier("voyageSharing.delay")
            Picker(session.mayHaveLink ? "New link expires after" : "Link expires after", selection: $duration) {
                Text("15 minutes").tag(900)
                Text("6 hours").tag(21_600)
                Text("1 day").tag(86_400)
                Text("7 days").tag(604_800)
            }
            if session.sharing == .on, let actualDelay = session.serverDelay, delay != actualDelay {
                Button("Apply Delay") { Task { await session.updateDelay(delay) } }
            }
            if let link = session.link {
                ShareLink(item: link) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                // This control exists only in the opted-in Debug simulator.
                .accessibilityIdentifier("voyageSharing.link")
                .accessibilityValue(link.absoluteString)
            }
            if let cutoff = session.uploadCutoff {
                LabeledContent("Uploads stop by") {
                    Text(cutoff, format: .dateTime.month().day().hour().minute())
                }
            }
            if session.pendingCount > 0 {
                LabeledContent("Positions queued", value: session.pendingCount.formatted())
            }
            if session.sharing == .off || session.sharing == .on || session.sharing == .paused {
                Button(session.mayHaveLink ? "Replace Link" : "Start Sharing") {
                    replacing = session.mayHaveLink
                    confirming = true
                }
            }
            if session.mayHaveLink {
                Button("Stop Sharing", role: .destructive) { Task { await session.stop() } }
            }
            if let message = session.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Live Sharing")
        } footer: {
            Text(
                "Uploads run while this screen is open. Anyone with the link can see the positions allowed by your delay and server privacy settings."
            )
        }
        .disabled(session.changing || phase != .active)
        .task(id: isActive) { await pollWhileVisible() }
        .onDisappear { session.clearPreview() }
        .onChange(of: session.serverDelay, initial: true) { _, current in
            if session.sharing == .on, let current { delay = current }
        }
        .confirmationDialog(
            replacing ? "Replace this voyage’s link?" : "Share this voyage’s position?",
            isPresented: $confirming
        ) {
            Button(replacing ? "Replace Link" : "Start Sharing") {
                guard replacing == session.mayHaveLink else { return }
                Task { await session.start(voyage: voyage, delay: delay, duration: duration, replacing: replacing) }
            }
        } message: {
            Text(
                "Only positions recorded after this link is issued can appear. Replacing a link disables the previous link."
            )
        }

        if session.mayHaveLink {
            Section {
                switch session.preview {
                case .case1:
                    Text("Position unavailable")
                case .case2(let projection):
                    let current = projection.current
                    let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
                    LabeledContent("Position") {
                        Text("\(current.lat, format: precision), \(current.lon, format: precision)")
                            .monospacedDigit()
                    }
                    LabeledContent("Captured") {
                        Text(
                            Date(timeIntervalSince1970: Double(current.capturedAtMs) / 1_000),
                            format: .dateTime.month().day().hour().minute().second()
                        )
                    }
                    LabeledContent("Visible track segments", value: projection.segments.count.formatted())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Visible track segments")
                        .accessibilityValue(projection.segments.count.formatted())
                        .accessibilityIdentifier("voyageSharing.visibleSegments")
                }
            } header: {
                Text("Viewer Preview")
            } footer: {
                Text("Not for navigation")
            }
        }
    }

    private var isActive: Bool { phase == .active && session.isBound }

    private func pollWhileVisible() async {
        guard isActive else {
            session.clearPreview()
            return
        }
        while !Task.isCancelled {
            await session.poll()
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
        }
    }
}
