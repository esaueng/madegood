import SwiftUI
import WaterKit

extension ConfirmationCard where Details == SessionDeleteSummary {
    /// Asks before deleting a session, from History or the session's ⋯ menu, and shows
    /// which session it is. Deleting moves it to Recently Deleted (`SessionLibrary.delete`).
    static func deleteSession(_ item: SessionLibrary.Item, delete: @escaping () -> Void) -> Self {
        ConfirmationCard(
            systemImage: "trash", tint: .red, title: "Delete this session?",
            message:
                "It moves to Recently Deleted in History, where you can recover it for \(RecentlyDeleted.retentionDays) days before it's removed from this iPhone.",
            top: ConfirmationChoice(
                title: "Delete Session", identifier: "session.confirmDelete", style: .destructive, action: delete),
            bottom: .backOut("Keep", identifier: "session.keep"),
            details: SessionDeleteSummary(item: item))
    }
}

/// The session a delete confirmation is about: the sport, its name, when, and the
/// headline numbers, as History shows them.
struct SessionDeleteSummary: View {
    let item: SessionLibrary.Item

    var body: some View {
        let sport = item.summary?.sport ?? item.entry.meta?.sport
        HStack(spacing: 12) {
            Group {
                if let sport {
                    SportIcon(sport: sport, size: 22)
                } else {
                    Image(systemName: "applewatch.radiowaves.left.and.right").font(.body)
                }
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.opacity(0.12), in: .circle)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
                if let startedAt = item.entry.startedAt {
                    Text(startedAt, format: .dateTime.weekday(.abbreviated).day().month().year().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let summary = item.summary {
                    let display = UserSettings.display(for: summary.sport)
                    Text(
                        Formatting.metricLine([
                            display.distance(summary.metrics.distance), Formatting.elapsed(summary.metrics.movingTime),
                        ])
                    )
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.deleteSummary")
    }
}
