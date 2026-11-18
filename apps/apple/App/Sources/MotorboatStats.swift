import SwiftUI
import WaterKit

/// The motorboat log (docs/PLAN.md §5): trip and total in the distance unit (nautical
/// miles by default), engine time, and the fuel estimate from the user's burn rate.
enum MotorboatStats {
    /// Saved motorboat trips in the history, for the running log.
    @MainActor
    static func savedTrips(_ library: SessionLibrary) -> [NauticalLog.Trip] {
        library.items.compactMap(\.summary).filter { $0.sport == .motorboating }.map {
            NauticalLog.Trip(startedAt: $0.startedAt.timeIntervalSince1970, distance: $0.metrics.distance)
        }
    }

    static func fuelText(_ estimate: FuelEstimate?, unit: VolumeUnit) -> String {
        guard let estimate else { return "–" }
        return unit.display(estimate.litres).text
    }

    static func burnRateText(_ model: FuelModel, unit: VolumeUnit) -> String {
        let rate = { (litres: Double) in
            ShortNumber.text((unit.fromLitres(litres) * 10).rounded() / 10)
        }
        var text = "\(rate(model.burnRate)) \(unit.symbol)/h under way"
        if model.idleBurnRate > 0 { text += ", \(rate(model.idleBurnRate)) \(unit.symbol)/h otherwise" }
        return text
    }
}

/// The motorboat page of a live session: trip, log, engine time and fuel.
struct MotorboatLiveCard: View {
    let readings: LiveReadings
    let display: LiveDisplay
    let savedTrips: [NauticalLog.Trip]
    @State private var store = SettingsStore.shared

    var body: some View {
        let settings = store[.motorboating]
        let log = NauticalLog(trip: readings.distance, saved: savedTrips)
        let estimate = readings.underWayTime.flatMap {
            settings.fuelModel?.estimate(underWayTime: $0, movingTime: readings.movingTime)
        }
        VStack(alignment: .leading, spacing: 12) {
            Label("Trip log", systemImage: "fuelpump")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    StatTile(title: "Trip", value: display.distance(log.trip), identifier: "motor.trip")
                    StatTile(title: "Log total", value: display.distance(log.total), identifier: "motor.log")
                }
                GridRow {
                    StatTile(
                        title: "Engine time", value: readings.underWayTime.map(Formatting.elapsed) ?? "–",
                        identifier: "motor.engineTime")
                    StatTile(
                        title: "Fuel (estimate)",
                        value: MotorboatStats.fuelText(estimate, unit: settings.fuelUnit),
                        identifier: "motor.fuel")
                }
            }
            Text(
                settings.fuelModel == nil
                    ? "Set a burn rate in Motorboating settings for a fuel estimate."
                    : "Fuel is an estimate from your burn rate, not a measurement."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("motor.card")
    }
}

/// The motorboat section of session detail.
struct MotorboatDetailSection: View {
    let metrics: LiveMetrics
    let startedAt: Date
    let display: LiveDisplay
    let library: SessionLibrary
    @State private var store = SettingsStore.shared

    var body: some View {
        let settings = store[.motorboating]
        let trip = NauticalLog.Trip(startedAt: startedAt.timeIntervalSince1970, distance: metrics.distance)
        let log = NauticalLog(savedTrip: trip, all: MotorboatStats.savedTrips(library))
        let estimate = settings.fuelModel?.estimate(metrics)
        Section {
            Grid(horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    StatTile(title: "Trip", value: display.distance(log.trip), identifier: "motor.trip")
                    StatTile(title: "Log to date", value: display.distance(log.total), identifier: "motor.log")
                }
                GridRow {
                    StatTile(
                        title: "Engine time", value: Formatting.elapsed(metrics.underWayTime),
                        identifier: "motor.engineTime")
                    StatTile(
                        title: "Fuel (estimate)", value: MotorboatStats.fuelText(estimate, unit: settings.fuelUnit),
                        identifier: "motor.fuel")
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Trip log")
        } footer: {
            if let model = settings.fuelModel {
                Text(
                    "Fuel is an estimate from \(MotorboatStats.burnRateText(model, unit: settings.fuelUnit)), not a measurement. Engine time counts moving time at \(display.speed(SessionEngine.underWaySpeed)) or faster."
                )
            } else {
                Text(
                    "Engine time counts moving time at \(display.speed(SessionEngine.underWaySpeed)) or faster. Set a burn rate in Motorboating settings for a fuel estimate."
                )
            }
        }
    }
}
