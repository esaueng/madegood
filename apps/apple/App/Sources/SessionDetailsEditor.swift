import SwiftUI
import WaterKit

/// Names a session and keeps notes on it. Both stay on this iPhone.
struct SessionDetailsEditor: View {
    let sport: Sport
    let save: (SessionDetails) throws -> Void
    @State private var name: String
    @State private var notes: String
    @State private var error: String?
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    private let original: SessionDetails

    private enum Field { case name, notes }

    init(details: SessionDetails, sport: Sport, save: @escaping (SessionDetails) throws -> Void) {
        original = details
        self.sport = sport
        self.save = save
        _name = State(initialValue: details.name)
        _notes = State(initialValue: details.notes)
    }

    var body: some View {
        let edited = SessionDetails(name: name, notes: notes)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(sport.displayName))
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .notes }
                        .accessibilityIdentifier("details.name")
                } header: {
                    Text("Name")
                } footer: {
                    if name.count > SessionDetails.maxNameLength {
                        Text("Names keep their first \(SessionDetails.maxNameLength) characters.")
                    }
                }
                Section {
                    TextField("Notes", text: $notes, prompt: Text("Conditions, gear, how it went"), axis: .vertical)
                        .lineLimit(5...)
                        .focused($focus, equals: .notes)
                        .accessibilityIdentifier("details.notes")
                } header: {
                    Text("Notes")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if notes.count > SessionDetails.maxNotesLength {
                            Text("Notes keep their first \(SessionDetails.maxNotesLength) characters.")
                        }
                        Text(
                            "Kept on this iPhone. They aren't uploaded or shared; an exported GPX file carries the name."
                        )
                    }
                }
            }
            .navigationTitle(original.isEmpty ? "Add Name & Notes" : "Edit Name & Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try save(edited)
                            dismiss()
                        } catch {
                            self.error = "Couldn't save the name and notes."
                        }
                    }
                    .disabled(edited == original)
                    .accessibilityIdentifier("details.save")
                }
            }
            .alert(
                "Name & Notes",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onAppear { if original.isEmpty { focus = .name } }
        }
        // Typing then swiping the sheet away shouldn't lose the edit silently.
        .interactiveDismissDisabled(edited != original)
    }
}
