import Foundation

#if os(watchOS)
    import WatchKit
#else
    import UIKit
#endif

/// Haptics for countdowns, laps and alerts, on the watch's Taptic Engine or the iPhone's.
enum Haptics {
    enum Event {
        case countdownStarted
        case countdownMinute
        case countdownSecond
        case sync
        case recordingStarted
        case lap
        case distanceAlert
        case mark
        case manOverboard
        /// The press did nothing it could confirm (no position for a MOB mark).
        case failure
    }

    @MainActor
    static func play(_ event: Event) {
        #if os(watchOS)
            let type: WKHapticType =
                switch event {
                case .countdownStarted, .recordingStarted: .start
                case .countdownMinute, .distanceAlert, .manOverboard: .notification
                case .countdownSecond, .lap, .mark: .click
                case .sync: .directionUp
                case .failure: .failure
                }
            WKInterfaceDevice.current().play(type)
        #else
            switch event {
            case .countdownStarted, .recordingStarted, .distanceAlert:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .manOverboard:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .failure:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .countdownMinute, .sync:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .countdownSecond, .lap, .mark:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        #endif
    }
}
