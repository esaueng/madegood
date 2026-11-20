import Foundation

/// Weather can be fetched again after the system purges this directory. Library/Caches
/// keeps these files out of the app's backed-up documents and preferences.
struct WeatherDiskCache {
    static let shared = Self(
        directory: URL.cachesDirectory.appending(path: "MadeGoodWeather", directoryHint: .isDirectory))

    enum Entry: String {
        case conditions = "conditions.json"
        case wind = "wind-v1.json"
        case attribution = "attribution.json"
    }

    let directory: URL

    func read<Value: Decodable>(_ type: Value.Type, for entry: Entry) -> Value? {
        let file = directory.appending(path: entry.rawValue)
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        remove(entry)
        return nil
    }

    func write<Value: Encodable>(_ value: Value, for entry: Entry) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: entry.rawValue), options: .atomic)
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: directory.appending(path: entry.rawValue))
    }
}
