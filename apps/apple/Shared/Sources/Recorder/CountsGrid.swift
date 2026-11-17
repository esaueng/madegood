import SwiftUI

/// Live sample counts while recording, so a dead sensor is obvious on the water.
struct CountsGrid: View {
    let counts: SessionRecorder.Counts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            GridRow {
                Text("GPS \(counts.gps)")
                Text("Motion \(counts.motion)")
            }
            GridRow {
                Text("HR \(counts.hr)")
                Text("Heading \(counts.heading)")
            }
            GridRow {
                Text("Marks \(counts.marks)")
                if counts.dropped > 0 { Text("Dropped \(counts.dropped)").foregroundStyle(.orange) }
            }
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
