import SwiftUI
import WaterKit

struct HeartRateZoneSettingsView: View {
    @State private var store = SettingsStore.shared

    var body: some View {
        let zones = store.heartRateZones
        Form {
            Section {
                Stepper(
                    "Maximum: \(zones.maximum) bpm",
                    value: Binding(
                        get: { store.heartRateZones.maximum },
                        set: { maximum in
                            store.updateHeartRateZones(
                                HeartRateZones(maximum: maximum, thresholds: store.heartRateZones.thresholds))
                        }),
                    in: HeartRateZones.maximumRange
                )
                .accessibilityIdentifier("settings.heartRateZones.maximum")
                if zones.maximum != HeartRateZones.defaultMaximum {
                    Button("Use Default Maximum") {
                        store.updateHeartRateZones(HeartRateZones(thresholds: store.heartRateZones.thresholds))
                    }
                }
            } footer: {
                Text(
                    "The default of \(HeartRateZones.defaultMaximum) bpm is a starting point. Use your own maximum if you know it."
                )
            }

            Section {
                ForEach(zones.thresholds.indices, id: \.self) { index in
                    Stepper(
                        "Zone \(index + 2): \(zones.thresholds[index])%",
                        value: Binding(
                            get: { store.heartRateZones.thresholds[index] },
                            set: { threshold in
                                let current = store.heartRateZones
                                var thresholds = current.thresholds
                                thresholds[index] = threshold
                                store.updateHeartRateZones(
                                    HeartRateZones(maximum: current.maximum, thresholds: thresholds))
                            }),
                        in: bounds(for: index, in: zones.thresholds)
                    )
                }
                if zones.thresholds != HeartRateZones.defaultThresholds {
                    Button("Use Default Thresholds") {
                        store.updateHeartRateZones(HeartRateZones(maximum: store.heartRateZones.maximum))
                    }
                }
            } header: {
                Text("Zone Thresholds")
            } footer: {
                Text("Each zone starts at its percentage of maximum. Zone 1 covers readings below Zone 2.")
            }
        }
        .navigationTitle("Heart Rate Zones")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bounds(for index: Int, in thresholds: [Int]) -> ClosedRange<Int> {
        let lower = index == 0 ? HeartRateZones.thresholdRange.lowerBound : thresholds[index - 1] + 1
        let upper = index == thresholds.count - 1 ? HeartRateZones.thresholdRange.upperBound : thresholds[index + 1] - 1
        return lower...upper
    }
}

#Preview {
    NavigationStack {
        HeartRateZoneSettingsView()
    }
}
