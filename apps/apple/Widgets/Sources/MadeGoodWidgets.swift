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
                    Label(context.attributes.sportName, systemImage: context.attributes.sportSymbol)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.speed).font(.title2.weight(.bold).monospacedDigit())
                        Spacer()
                        Text(context.state.distance).font(.title3.monospacedDigit())
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.sportSymbol)
            } compactTrailing: {
                Text(context.state.speedNumber).monospacedDigit().font(.caption.weight(.semibold))
            } minimal: {
                Image(systemName: context.attributes.sportSymbol)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(context.attributes.sportName, systemImage: context.attributes.sportSymbol)
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
        .foregroundStyle(.white)
    }
}
