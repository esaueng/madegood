import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MadeGoodWidgets: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}

/// Speed, elapsed time and distance on the Lock Screen and in the Dynamic Island.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.sportName)
                    } icon: {
                        SportImage(attributes: context.attributes, size: 16)
                    }
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(context.state.speed).font(.title2.weight(.bold).monospacedDigit())
                            Spacer()
                            Text(context.state.distance).font(.title3.monospacedDigit())
                        }
                        if let mob = context.state.manOverboard {
                            ManOverboardLine(text: mob)
                        }
                    }
                }
            } compactLeading: {
                if context.state.manOverboard != nil {
                    ManOverboardIcon()
                } else {
                    SportImage(attributes: context.attributes, size: 20, labeled: true)
                }
            } compactTrailing: {
                Text(context.state.speedNumber).monospacedDigit().font(.caption.weight(.semibold))
            } minimal: {
                if context.state.manOverboard != nil {
                    ManOverboardIcon()
                } else {
                    SportImage(attributes: context.attributes, size: 20, labeled: true)
                }
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mob = context.state.manOverboard {
                ManOverboardLine(text: mob)
            }
            metrics
        }
        .foregroundStyle(.white)
    }

    private var metrics: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(context.attributes.sportName)
                } icon: {
                    SportImage(attributes: context.attributes, size: 18)
                }
                .font(.subheadline.weight(.semibold))
                if let pause = context.state.pauseLabel {
                    Text(pause).font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                } else {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.speed).font(.title.weight(.bold).monospacedDigit())
                Text("\(context.state.distance) · \(context.state.movingTime)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The man-overboard mark: distance and true bearing back to it, in red.
private struct ManOverboardLine: View {
    let text: String

    var body: some View {
        Label {
            Text("MOB · \(text)").monospacedDigit()
        } icon: {
            Image(systemName: "figure.wave")
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.red)
        .accessibilityLabel("Man overboard, \(text)")
    }
}

private struct ManOverboardIcon: View {
    var body: some View {
        Image(systemName: "figure.wave")
            .foregroundStyle(.red)
            .accessibilityLabel("Man overboard")
    }
}

/// The sport's icon from the shared asset catalog (Shared/Resources/SportIcons.xcassets), or
/// the SF Symbol an activity from an earlier build carries. Decorative unless `labeled`,
/// when VoiceOver reads the sport's name.
private struct SportImage: View {
    let attributes: SessionActivityAttributes
    let size: CGFloat
    var labeled = false

    var body: some View {
        let image = attributes.isLegacySymbol ? Image(systemName: attributes.sportIcon) : Image(attributes.sportIcon)
        let sized = image.resizable().scaledToFit().frame(width: size, height: size)
        if labeled {
            sized.accessibilityLabel(attributes.sportName)
        } else {
            sized.accessibilityHidden(true)
        }
    }
}
