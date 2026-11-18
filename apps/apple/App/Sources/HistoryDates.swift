import SwiftUI

enum HistoryDates: Hashable {
    case all, lastWeek, lastMonth, thisYear
    case custom(start: Date, end: Date)

    static let presets: [Self] = [.all, .lastWeek, .lastMonth, .thisYear]

    var title: String {
        switch self {
        case .all: "All Dates"
        case .lastWeek: "Last 7 Days"
        case .lastMonth: "Last 30 Days"
        case .thisYear: "This Year"
        case .custom: "Custom Dates"
        }
    }

    /// Local calendar days, including today for the rolling presets and both selected days for a custom range.
    func range(on now: Date, calendar: Calendar) -> Range<Date>? {
        switch self {
        case .all:
            return nil
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now).map { $0.start..<$0.end }
        case .lastWeek, .lastMonth:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: self == .lastWeek ? -6 : -29, to: today) else {
                return nil
            }
            return Self.days(from: start, through: today, calendar: calendar)
        case .custom(let start, let end):
            return Self.days(from: start, through: end, calendar: calendar)
        }
    }

    private static func days(from start: Date, through end: Date, calendar: Calendar) -> Range<Date>? {
        let firstDay = calendar.startOfDay(for: start)
        guard let nextDay = calendar.dateInterval(of: .day, for: end)?.end, firstDay < nextDay else { return nil }
        return firstDay..<nextDay
    }
}

struct HistoryDateRangePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var start: Date
    @State private var end: Date
    let apply: (Date, Date) -> Void

    init(range: Range<Date>?, apply: @escaping (Date, Date) -> Void) {
        // The range ends at the start of the next day; show the last included date.
        _start = State(initialValue: range?.lowerBound ?? .now)
        _end = State(initialValue: range?.upperBound.addingTimeInterval(-1) ?? .now)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("Through", selection: $end, displayedComponents: .date)
            }
            .datePickerStyle(.compact)
            .navigationTitle("Choose Dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(start, end)
                        dismiss()
                    }
                    .disabled(calendar.startOfDay(for: start) > calendar.startOfDay(for: end))
                }
            }
        }
    }
}
