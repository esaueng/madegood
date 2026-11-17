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
    }

    @MainActor
    static func play(_ event: Event) {
        #if os(watchOS)
            let type: WKHapticType =
                switch event {
                case .countdownStarted, .recordingStarted: .start
                case .countdownMinute, .distanceAlert: .notification
                case .countdownSecond, .lap: .click
                case .sync: .directionUp
                }
            WKInterfaceDevice.current().play(type)
        #else
            switch event {
            case .countdownStarted, .recordingStarted, .distanceAlert:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .countdownMinute, .sync:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .countdownSecond, .lap:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        #endif
    }
}
