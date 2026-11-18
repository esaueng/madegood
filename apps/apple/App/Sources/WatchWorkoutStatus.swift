import SwiftUI

struct WatchWorkoutStatus: View {
    let snapshot: WorkoutMirrorSnapshot?
    let connected: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let mirror = WatchWorkoutMirror.shared
            let canDismiss = connected && mirror.isStale(at: context.date)
            let isCurrent = connected && !canDismiss
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if let snapshot {
                        let confirmed = LiveDisplay.pauseLabel(snapshot.readings.pauseState) ?? "Recording"
                        heading(isCurrent ? confirmed : "Status unknown")
                        if isCurrent {
                            if let lap = snapshot.readings.lap {
                                Text("Lap \(lap)")
                            }
                        } else {
                            let age = Formatting.duration(snapshot.age(at: context.date))
                            Text("Last confirmed: \(snapshot.sport.displayName), \(confirmed), \(age) ago")
                        }
                    } else {
                        heading(isCurrent ? "Waiting for Apple Watch" : "Status unknown")
                    }
                    if !isCurrent { Text("Check your watch for the current recording status.") }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("status.watchWorkout")
                if canDismiss {
                    Button("Return to Record", action: mirror.dismissStale)
                        .accessibilityHint("Your Apple Watch may still be recording")
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(_ status: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { labels(status) }
            VStack(alignment: .leading, spacing: 4) { labels(status) }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func labels(_ status: String) -> some View {
        Group {
            Text(status)
            Label("On Watch", systemImage: "applewatch")
                .foregroundStyle(.secondary)
        }
    }
}
