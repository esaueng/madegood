import SwiftUI
import WaterKit

/// Deleted sessions, kept for `RecentlyDeleted.retentionDays` so a delete can be undone.
/// Tap one, or swipe it, to recover it or delete it for good.
struct RecentlyDeletedView: View {
    let library: SessionLibrary
    @State private var chosen: SessionLibrary.DeletedItem?
    @State private var confirmDelete: SessionLibrary.DeletedItem?
    /// The deleted sessions shown when Delete All was tapped: the ones the card deletes.
    @State private var deletingAll: [SessionLibrary.DeletedItem]?
    @State private var operationError: String?

    var body: some View {
        List {
            if !library.deleted.isEmpty {
                Section {
                    ForEach(library.deleted) { item in
                        Button {
                            chosen = item
                        } label: {
                            DeletedSessionRow(item: item)
                        }
                        .tint(.primary)
                        .accessibilityIdentifier("deleted.row")
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button("Recover", systemImage: "arrow.uturn.backward") { recover(item) }
                                .tint(.accentColor)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Not a destructive role: that removes the row before the user confirms.
                            Button("Delete", systemImage: "trash") { confirmDelete = item }
                                .tint(.red)
                                .accessibilityIdentifier("deleted.row.delete")
                        }
                    }
                } footer: {
                    Text(
                        "Sessions stay here for \(RecentlyDeleted.retentionDays) days, then they're deleted from this iPhone for good."
                    )
                }
            }
        }
        .overlay {
            if library.deleted.isEmpty {
                ContentUnavailableView(
                    "No Recently Deleted Sessions", systemImage: "trash",
                    description: Text(
                        "Sessions you delete stay here for \(RecentlyDeleted.retentionDays) days before they're removed."
                    ))
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            if !library.deleted.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Recover All", systemImage: "arrow.uturn.backward") { recoverAll() }
                        Button("Delete All", systemImage: "trash", role: .destructive) { deletingAll = library.deleted }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("deleted.more")
                }
            }
        }
        .confirmationDialog(
            chosen?.title ?? "", isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
            titleVisibility: .visible, presenting: chosen
        ) { item in
            Button("Recover") { recover(item) }
            Button("Delete Permanently", role: .destructive) { deletePermanently([item]) }
        } message: { item in
            Text(Self.remaining(item))
        }
        .confirmationCard(item: $confirmDelete) { item in
            ConfirmationCard(
                systemImage: "trash", tint: .red, title: "Delete this session permanently?",
                message: "It's removed from this iPhone, with its name, notes and trim. This can't be undone.",
                top: ConfirmationChoice(
                    title: "Delete Permanently", identifier: "deleted.confirmDelete", style: .destructive
                ) { deletePermanently([item]) },
                bottom: .backOut("Keep", identifier: "deleted.keep"))
        }
        .confirmationCard(item: $deletingAll) { items in
            ConfirmationCard(
                systemImage: "trash", tint: .red,
                title: "Delete all \(items.count) sessions permanently?",
                message: "They're removed from this iPhone, with their names, notes and trims. This can't be undone.",
                top: ConfirmationChoice(
                    title: "Delete All", identifier: "deleted.confirmDeleteAll", style: .destructive
                ) { deletePermanently(items) },
                bottom: .backOut("Keep All", identifier: "deleted.keepAll"))
        }
        .alert(
            "Recently Deleted",
            isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "")
        }
        .onAppear { library.reload() }
    }

    static func remaining(_ item: SessionLibrary.DeletedItem, now: Date = .now) -> String {
        let days = item.entry.daysLeft(now: now)
        return "Deleted from this iPhone in \(days) \(days == 1 ? "day" : "days")."
    }

    private func recover(_ item: SessionLibrary.DeletedItem) {
        do {
            try library.recover(item)
        } catch RecentlyDeleted.RestoreError.alreadyInHistory {
            operationError = "History already has this session. Delete that copy first to recover this one."
        } catch {
            operationError = "Couldn't recover this session."
        }
    }

    private func recoverAll() {
        var failed = 0
        for item in library.deleted {
            do { try library.recover(item) } catch { failed += 1 }
        }
        if failed > 0 {
            operationError =
                failed == 1
                ? "One session couldn't be recovered. History may already have it."
                : "\(failed) sessions couldn't be recovered. History may already have them."
        }
    }

    private func deletePermanently(_ items: [SessionLibrary.DeletedItem]) {
        var failed = 0
        for item in items {
            do { try library.deletePermanently(item) } catch { failed += 1 }
        }
        if failed > 0 {
            operationError = failed == 1 ? "Couldn't delete a session." : "Couldn't delete \(failed) sessions."
        }
    }
}

/// The sport, the session's name (or its sport's), when it was recorded, and the days left.
private struct DeletedSessionRow: View {
    let item: SessionLibrary.DeletedItem

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let sport = item.entry.meta?.sport {
                    SportIcon(sport: sport, size: 22)
                } else {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.semibold)).lineLimit(2)
                if let startedAt = item.entry.startedAt {
                    Text(startedAt, format: .dateTime.weekday(.abbreviated).day().month().year().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            let days = item.entry.daysLeft(now: .now)
            Text("\(days) \(days == 1 ? "day" : "days")")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(RecentlyDeletedView.remaining(item))
        }
        .accessibilityElement(children: .combine)
    }
}
