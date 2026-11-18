import SwiftUI

struct WatchWorkoutStatus: View {
    let snapshot: WorkoutMirrorSnapshot
    let connected: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = snapshot.age(at: context.date)
            let isCurrent = connected && age < WatchWorkoutMirror.staleAfter
            let confirmed = LiveDisplay.pauseLabel(snapshot.readings.pauseState) ?? "Recording"
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack { labels(isCurrent ? confirmed : "Status unknown") }
                    VStack(alignment: .leading, spacing: 4) { labels(isCurrent ? confirmed : "Status unknown") }
                }
                .font(.subheadline.weight(.semibold))

                if isCurrent {
                    if let lap = snapshot.readings.lap {
                        Text("Lap \(lap)").font(.footnote)
                    }
                } else {
                    Text("Last confirmed: \(snapshot.sport.displayName), \(confirmed), \(Formatting.duration(age)) ago")
                    Text("Check your watch for the current recording status.")
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.watchWorkout")
    }

    private func labels(_ status: String) -> some View {
        Group {
            Text(status)
            Label("On Watch", systemImage: "applewatch")
                .foregroundStyle(.secondary)
        }
    }
}
