import SwiftUI
import WaterKit

/// The start line during a sailing countdown: ping buttons for both ends, then distance and
/// time to the line, time to burn and the favoured end. Shared by the watch's line page
/// and the iPhone countdown. `remaining` is the countdown's time left, s.
struct StartLinePanel: View {
    let startLine: StartLineController
    let remaining: Double
    let display: LiveDisplay
    /// The watch's smaller type and tighter spacing.
    var compact = false

    var body: some View {
        let reading = startLine.reading(remaining: remaining)
        VStack(spacing: compact ? 4 : 10) {
            HStack(spacing: compact ? 6 : 12) {
                pingButton(.pin)
                pingButton(.boat)
            }
            if let failed = startLine.lastPingFailed {
                Text("No GPS fix for the \(failed == .pin ? "pin" : "boat")")
                    .font(compact ? .caption2 : .footnote)
                    .foregroundStyle(Theme.coral)
                    .accessibilityIdentifier("startLine.pingFailed")
            }
            if reading.line != nil {
                readings(reading)
            } else if startLine.hasUnusableEnds {
                Text("Ends too close or too far apart. Ping again.")
                    .font(compact ? .caption2 : .footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(compact ? "Ping both ends" : "Ping each end of the line as you pass it.")
                    .font(compact ? .caption2 : .footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("Not for navigation")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("startLine.notForNavigation")
        }
    }

    @ViewBuilder
    private func readings(_ reading: StartLineController.Reading) -> some View {
        if let position = reading.position {
            VStack(spacing: 0) {
                Text(display.lineDistance(position.distance))
                    .font(.system(size: compact ? 30 : 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(position.isOver ? Theme.coral : .primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(
                    position.isOver ? "Over the line" : (position.isBetweenEnds ? "to line" : "to line (outside ends)")
                )
                .font(compact ? .caption2 : .footnote.weight(.semibold))
                .foregroundStyle(position.isOver ? Theme.coral : .secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                position.isOver
                    ? "Over the line by \(display.lineDistance(position.distance))"
                    : "\(display.lineDistance(position.distance)) to line"
            )
            .accessibilityIdentifier("startLine.distance")
            HStack(spacing: compact ? 10 : 24) {
                value(
                    title: "To line", text: position.timeToLine.map { Formatting.elapsed($0.rounded()) } ?? "–",
                    id: "startLine.timeToLine")
                value(
                    title: (reading.timeToBurn ?? 0) < -0.5 ? "Late" : "Burn",
                    text: reading.timeToBurn.map(LiveDisplay.signedTime) ?? "–", id: "startLine.burn",
                    warning: (reading.timeToBurn ?? 0) < -0.5)
            }
        } else {
            Text("Waiting for GPS")
                .font(compact ? .caption2 : .footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("startLine.waiting")
        }
        if let bias = reading.bias {
            Text("Favoured: \(LiveDisplay.bias(bias))")
                .font(compact ? .caption2 : .footnote.weight(.semibold))
                .foregroundStyle(compact ? Theme.brightTeal : Color.accentColor)
                .accessibilityLabel(
                    bias.favoured == nil
                        ? "Line square to the wind"
                        : "\(bias.favoured == .pin ? "Pin" : "Boat") end favoured by \(Int(abs(bias.degrees).rounded())) degrees"
                )
                .accessibilityIdentifier("startLine.bias")
        }
    }

    private func value(title: String, text: String, id: String, warning: Bool = false) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font((compact ? Font.body : .title3).weight(.semibold).monospacedDigit())
                .foregroundStyle(warning ? Theme.coral : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(text)")
        .accessibilityIdentifier(id)
    }

    private func pingButton(_ end: StartLineEnd) -> some View {
        let name = end == .pin ? "Pin" : "Boat"
        let isSet = startLine.ping(end) != nil
        let isPending = startLine.pending == end
        return Button {
            startLine.startPing(end)
        } label: {
            HStack(spacing: 4) {
                if isPending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isSet ? "checkmark.circle.fill" : (end == .pin ? "flag" : "ferry"))
                }
                Text(name)
            }
            .font((compact ? Font.footnote : .headline).weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: compact ? 32 : 44)
        }
        .buttonStyle(.glass)
        .tint(isSet ? Theme.brightTeal : nil)
        .disabled(startLine.pending != nil)
        .accessibilityLabel(isPending ? "Pinging \(name.lowercased()) end" : "Ping \(name.lowercased()) end")
        .accessibilityValue(isSet ? "Set" : "Not set")
        .accessibilityIdentifier("startLine.ping.\(end.rawValue)")
    }
}

/// The start check's warning after the gun: over ("OCS: return"), possibly over, or
/// unknown (no GPS at the gun). Shown on the session screens until the boat is back
/// behind the line, the user dismisses it, or it times out.
struct OCSBanner: View {
    let warning: OCSWarning
    let display: LiveDisplay
    var compact = false
    let dismiss: () -> Void

    private var title: String {
        switch warning.check {
        case .over: "OCS: return"
        case .possiblyOver: "Possibly OCS"
        case .unknown: "OCS unknown"
        case .clear: ""
        }
    }

    private var detail: String {
        switch warning.check {
        case .over(let distance): "Over by \(display.lineDistance(distance)) at the start"
        case .possiblyOver(let distance): "\(display.lineDistance(distance)) behind, within GPS error"
        case .unknown: "No GPS fix at the start"
        case .clear: ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: warning.check == .unknown ? "location.slash" : "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font((compact ? Font.footnote : .headline).weight(.bold))
                Text(detail)
                    .font(compact ? .caption2 : .footnote)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss start warning")
            .accessibilityIdentifier("ocs.dismiss")
        }
        .foregroundStyle(.white)
        .padding(compact ? 8 : 12)
        .background(
            warning.check == .unknown ? Color.gray : Theme.coral, in: .rect(cornerRadius: compact ? 12 : 16)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ocs.banner")
    }
}
