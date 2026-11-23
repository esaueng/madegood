import SwiftUI

/// A full-screen question before something that can't be undone (clearing a man-overboard
/// mark, ending a session), in place of the system dialog. Laid out for wet hands: the safe
/// choice sits where the button that opened it was, so a double tap or a second press from
/// a wave or a sleeve lands on it, and the destructive choice is above it
/// (`FingerAnchoredLayout`).
struct WatchConfirmation: View {
    struct Choice {
        let title: String
        let id: String
    }

    let symbol: String
    let title: String
    let message: String?
    let confirm: Choice
    let keep: Choice
    /// Where the opening button's center was, in global coordinates (`.global`); nil puts
    /// the buttons at the bottom.
    let fingerY: CGFloat?
    let onConfirm: () -> Void
    let onKeep: () -> Void

    var body: some View {
        // Full screen: the cover's safe area keeps room for a navigation bar it doesn't
        // show, which would push the buttons off the opening button.
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            ScrollView {
                FingerAnchoredLayout(
                    // The scroll content starts at the top of the screen, unscrolled.
                    fingerY: fingerY.map { $0 - frame.minY },
                    height: proxy.size.height
                ) {
                    // VoiceOver reads the title, the consequence, then the choices, wherever
                    // the layout puts them.
                    titleBlock.accessibilitySortPriority(4)
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("confirmation.message")
                            .accessibilitySortPriority(3)
                    }
                    Button(role: .destructive, action: onConfirm) {
                        Text(confirm.title).bold().confirmationButtonLabel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier(confirm.id)
                    .accessibilitySortPriority(2)
                    Button(action: onKeep) {
                        Text(keep.title).confirmationButtonLabel()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(keep.id)
                    .accessibilitySortPriority(1)
                }
                .accessibilityElement(children: .contain)
                .padding(.horizontal, 10)
                .frame(width: proxy.size.width)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea()
        .background(.black)
    }

    /// The symbol and the title, or only the title when the space above the buttons is too
    /// short for the symbol.
    private var titleBlock: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(.red.opacity(0.22), in: Circle())
                    .accessibilityHidden(true)
                titleText
            }
            titleText
        }
        .frame(maxWidth: .infinity)
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("confirmation.title")
    }
}

/// Lays out the title block, an optional message, the destructive button and the safe
/// button (in that subview order), at least `height` tall. The safe button is centered on
/// `fingerY` (from the top; shifted up from the bottom corners while it still covers it)
/// with the destructive button above it, and the text above them, in the first arrangement
/// that fits:
/// 1. the title block (with its symbol if there's room) and the message above the buttons;
/// 2. the title above, the message below the buttons;
/// 3. everything in reading order, with the buttons starting below `fingerY` so that only
///    empty space is under the finger; the page scrolls to them.
/// Without `fingerY`, the buttons sit at the bottom.
private struct FingerAnchoredLayout: Layout {
    let fingerY: CGFloat?
    let height: CGFloat
    private let spacing: CGFloat = 6
    private let textSpacing: CGFloat = 4
    /// Kept clear at the top for the clock, and at the bottom for the screen's corners.
    private let topClearance: CGFloat = 32
    private let bottomClearance: CGFloat = 8
    /// Kept between the finger and the destructive button when the safe one can't be there.
    private let fingerClearance: CGFloat = 12

    private struct Frames {
        /// Each subview's top, and the height offered to it (nil: as tall as it likes).
        var tops: [CGFloat] = []
        var proposals: [CGFloat?] = []
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: frames(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() where index < frames.tops.count {
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + frames.tops[index]), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: frames.proposals[index]))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> Frames {
        guard subviews.count == 3 || subviews.count == 4 else { return Frames() }
        let free = ProposedViewSize(width: width, height: nil)
        let title = subviews[0]
        let message = subviews.count == 4 ? subviews[1] : nil
        let confirm = subviews[subviews.count - 2].sizeThatFits(free).height
        let keep = subviews[subviews.count - 1].sizeThatFits(free).height
        let pair = confirm + spacing + keep
        let messageHeight = message?.sizeThatFits(free).height ?? 0
        let messageBlock = message == nil ? 0 : messageHeight + textSpacing

        let lowest = height - bottomClearance - pair
        var top = lowest
        if let fingerY {
            top = fingerY - keep / 2 - spacing - confirm
            top -= min(max(0, top - lowest), keep / 2 - 6)
        }
        let room = top - spacing - topClearance
        /// The title block's height in at most `limit`, if it fits.
        func titleFitting(_ limit: CGFloat) -> CGFloat? {
            guard limit > 0 else { return nil }
            let fitted = title.sizeThatFits(ProposedViewSize(width: width, height: limit)).height
            return fitted <= limit ? fitted : nil
        }
        func result(_ tops: [CGFloat], titleProposal: CGFloat?, pairTop: CGFloat, bottom: CGFloat) -> Frames {
            let buttons = [pairTop, pairTop + confirm + spacing]
            return Frames(
                tops: tops + buttons, proposals: [titleProposal] + (message == nil ? [] : [nil]) + [nil, nil],
                height: max(height, max(bottom, pairTop + pair) + bottomClearance))
        }

        if let fitted = titleFitting(room - messageBlock) {
            let titleTop = top - spacing - messageBlock - fitted
            let messageTops = message == nil ? [] : [top - spacing - messageHeight]
            return result([titleTop] + messageTops, titleProposal: room - messageBlock, pairTop: top, bottom: 0)
        }
        if message != nil, let fitted = titleFitting(room) {
            let messageTop = top + pair + spacing
            return result(
                [top - spacing - fitted, messageTop], titleProposal: room, pairTop: top,
                bottom: messageTop + messageHeight)
        }
        let titleHeight = title.sizeThatFits(free).height
        let messageTop = topClearance + titleHeight + textSpacing
        let textBottom = topClearance + titleHeight + messageBlock
        let pairTop = max(textBottom + spacing, (fingerY ?? 0) + fingerClearance)
        return result(
            [topClearance] + (message == nil ? [] : [messageTop]), titleProposal: nil, pairTop: pairTop, bottom: 0)
    }
}

extension View {
    /// A large full-width button label, as the confirmation's buttons use.
    func confirmationButtonLabel() -> some View {
        multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    /// Reports where this view's center is, in global coordinates, for `WatchConfirmation`.
    func reportsFingerY(_ fingerY: Binding<CGFloat?>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { fingerY.wrappedValue = $0 }
    }

    /// Presents `content` full screen while `item` is set. It also backs out (the safe
    /// choice) when the app leaves the screen, for example after a press of the Digital
    /// Crown, so returning never finds a destructive question waiting.
    func watchConfirmation<Item: Identifiable>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        modifier(WatchConfirmationPresenter(item: item, body: content))
    }
}

private struct WatchConfirmationPresenter<Item: Identifiable, Body: View>: ViewModifier {
    @Binding var item: Item?
    let body: (Item) -> Body
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $item) { item in
                body(item)
                    // The real Action button keeps working over the question.
                    .uiTestHooks(actionButtonID: "debug.actionButtonOverConfirmation")
                    // Its own close button would push the question down; Keep backs out.
                    .toolbar(.hidden, for: .navigationBar)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { item = nil }
            }
    }
}

extension View {
    /// Debug-build stand-ins for UI tests, on the app and on each full-screen confirmation
    /// (presentations don't inherit them). `-uiTestActionButton` adds a button for the
    /// Action button, which UI tests can't press, with `id`; `-uiTestLargestText` sets the
    /// largest accessibility text size, for layout tests.
    @ViewBuilder
    func uiTestHooks(actionButtonID id: String = "debug.actionButton") -> some View {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            overlay(alignment: .topLeading) {
                if UserDefaults.standard.bool(forKey: "uiTestActionButton") {
                    Button("Action") { SessionController.shared.actionButtonPressed() }
                        .accessibilityIdentifier(id)
                        .font(.caption2)
                        .buttonStyle(.plain)
                }
            }
            // Every size, as without it, unless asked for the largest.
            .dynamicTypeSize((arguments.contains("-uiTestLargestText") ? .accessibility5 : .xSmall) ... .accessibility5)
        #else
            self
        #endif
    }
}
