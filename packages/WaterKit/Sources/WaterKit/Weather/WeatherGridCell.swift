/// A weather location snapped to the nearest tenth of a degree on both axes.
/// Cells are 0.1° × 0.1° (about 11 km north–south, and 11 km east–west at the equator).
/// Integer indices give equivalent positions the same identity, including ±180° and the poles.
public struct WeatherGridCell: Hashable, Sendable {
    private let latitudeIndex: Int
    private let longitudeIndex: Int

    public var latitude: Double { Double(latitudeIndex) / 10 }
    public var longitude: Double { Double(longitudeIndex) / 10 }

    public init?(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        latitudeIndex = Int((latitude * 10).rounded())
        let meridian = Int((longitude * 10).rounded())
        longitudeIndex = abs(latitudeIndex) == 900 ? 0 : meridian == 1800 ? -1800 : meridian
    }
}
