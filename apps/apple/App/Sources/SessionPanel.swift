import SwiftUI

/// The heights the session panel rests at.
enum PanelDetent: Int, CaseIterable, Comparable {
    case low, middle, high

    /// The share of the screen below the navigation bar.
    var fraction: CGFloat {
        switch self {
        case .low: 0.4
        case .middle: 0.62
        case .high: 0.9
        }
    }

    var title: String {
        switch self {
        case .low: "Replay"
        case .middle: "Half"
        case .high: "Full"
        }
    }

    func height(in available: CGFloat) -> CGFloat { (available * fraction).rounded() }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The session detail's panel over the full-screen map. It rests at three heights: low
/// for the replay with most of the map showing, middle for the stats, high for reading.
/// It is a view in the screen, not a presented sheet, so the app's own sheets (man
/// overboard, anchor alarm) can always present over it.
///
/// The header (grabber and title) drags it; the content scrolls on its own. VoiceOver
/// adjusts the height from the grabber.
struct SessionPanel<Header: View, Content: View>: View {
    @Binding var detent: PanelDetent
    /// The height the panel's fractions apply to (the screen below the navigation bar).
    let available: CGFloat
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        let resting = detent.height(in: available)
        let height = min(available, max(PanelDetent.low.height(in: available) * 0.6, resting - drag))
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 36, height: 5)
                    .padding(.top, 7)
                    .accessibilityElement()
                    .accessibilityLabel("Panel size")
                    .accessibilityValue(detent.title)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: step(by: 1)
                        case .decrement: step(by: -1)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction { step(by: detent == .high ? -2 : 1) }
                    .accessibilityIdentifier("session.panel.handle")
                header
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { step(by: detent == .high ? -2 : 1) }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in settle(at: resting - value.predictedEndTranslation.height) }
            )
            content
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(Color(.systemGroupedBackground))
                .shadow(color: .black.opacity(0.25), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(.snappy(duration: 0.3), value: detent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.panel")
    }

    private func step(by offset: Int) {
        let next = PanelDetent(rawValue: min(PanelDetent.high.rawValue, max(0, detent.rawValue + offset))) ?? detent
        detent = next
    }

    /// The nearest resting height to where a fling would end.
    private func settle(at height: CGFloat) {
        detent =
            PanelDetent.allCases.min {
                abs($0.height(in: available) - height) < abs($1.height(in: available) - height)
            } ?? detent
    }
}
