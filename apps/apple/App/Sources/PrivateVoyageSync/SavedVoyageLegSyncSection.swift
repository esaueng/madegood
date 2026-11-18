import SwiftUI
import WaterKit

struct SavedVoyageLegSyncSection: View {
    let voyage: Voyage
    let leg: VoyageLeg
    let recorder: VoyageRecorder
    @Environment(PrivateVoyageSync.self) private var sync
    @State private var consentBinding: VoyageAccountBinding?
    @State private var confirming = false
    @State private var preparationFailed = false

    var body: some View {
        Section("Private Sync") {
            let status = sync.outbox.status(for: leg.id)
            Text(statusText(status))
                .accessibilityIdentifier("voyageSync.legStatus")
            if status == .onIPhone, let binding = sync.account.binding {
                Button("Sync Leg Privately") {
                    consentBinding = binding
                    confirming = true
                    preparationFailed = false
                }
            } else if status == .waitingForConnection || canRetry(status) {
                Button("Retry Sync", action: sync.retryNow)
            }
            if preparationFailed {
                Text("Couldn’t queue this leg. Try again with your current sign-in.")
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Sync this leg with the signed-in account?", isPresented: $confirming) {
            Button("Sync Privately", action: enqueue)
            Button("Cancel", role: .cancel) { consentBinding = nil }
        } message: {
            Text("The voyage details and recorded track will be saved to your MadeGood account.")
        }
    }

    private func enqueue() {
        guard let binding = consentBinding else { return }
        defer { consentBinding = nil }
        do {
            let snapshot = try VoyageRecorderSync.prepare(voyage: voyage, leg: leg)
            try sync.enqueue(snapshot, for: binding) {
                try VoyageRecorderSync.encodeTrack(leg: leg, points: recorder.track(for: leg))
            }
        } catch {
            preparationFailed = true
        }
    }

    private func canRetry(_ status: VoyageSyncStatus) -> Bool {
        if case .retryableFailure = status { return true }
        return false
    }

    private func statusText(_ status: VoyageSyncStatus) -> String {
        switch status {
        case .onIPhone: "On iPhone"
        case .queued: "Queued"
        case .waitingForConnection: "Waiting for connection"
        case .syncing: "Syncing"
        case .synced: "Synced"
        case .retryableFailure: "Retryable failure"
        case .needsAttention(_, 409): "Sync conflict"
        case .needsAttention: "Needs attention"
        }
    }
}
