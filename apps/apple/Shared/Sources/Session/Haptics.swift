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
                }
            WKInterfaceDevice.current().play(type)
        #else
            switch event {
            case .countdownStarted, .recordingStarted, .distanceAlert:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .manOverboard:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .countdownMinute, .sync:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .countdownSecond, .lap, .mark:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        #endif
    }
}
