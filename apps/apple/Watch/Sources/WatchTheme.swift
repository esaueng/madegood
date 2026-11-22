import SwiftUI

extension Theme {
    /// One color per kind of metric, as on the iPhone (App/Sources/Theme.swift): its
    /// dark-mode values, since the watch is always dark.
    enum Metric {
        static let distance = hex(0x4AAED4)
        static let time = hex(0x3CC2B1)
        static let speed = hex(0xEE7B57)
        static let heartRate = hex(0xFF6B70)

        private static func hex(_ value: UInt32) -> Color {
            Color(
                red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255)
        }
    }
}
