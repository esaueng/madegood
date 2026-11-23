import SwiftUI
import UIKit

/// One way to ask before acting on the iPhone: a short sheet from the bottom with an icon,
/// a title, what is affected, and two full-width buttons, the second of which names how to
/// back out. Swiping it down backs out too.
///
/// It replaces `.confirmationDialog`, which on iOS 26 and later shows as a popover that
/// hides every Cancel button (back out by tapping outside) and, by default, the title.
/// Where acting is the risky choice, put the safe choice on top, filled.
struct ConfirmationCard<Details: View> {
    var systemImage: String
    /// The icon's color: red for removing or turning something off, the accent otherwise.
    var tint: Color
    var title: String
    var message: String
    /// The top, filled button.
    var top: ConfirmationChoice
    /// The bottom, grey button.
    var bottom: ConfirmationChoice
    /// What the confirmation is about (a session, say), between the title and message.
    var details: Details
}

extension ConfirmationCard where Details == EmptyView {
    init(
        systemImage: String, tint: Color, title: String, message: String, top: ConfirmationChoice,
        bottom: ConfirmationChoice
    ) {
        self.init(
            systemImage: systemImage, tint: tint, title: title, message: message, top: top, bottom: bottom,
            details: EmptyView())
    }
}

/// One of a confirmation card's two buttons.
struct ConfirmationChoice {
    enum Style {
        /// Filled red: deletes, turns off or clears something.
        case destructive
        /// Filled with the app's accent: a choice that removes nothing, or the safe choice.
        case prominent
        /// Grey: backing out.
        case plain
        /// Grey with orange text: going ahead with a risky choice.
        case caution
    }

    var title: String
    var identifier: String
    var style: Style
    var action: () -> Void = {}

    /// A grey button that closes the card and does nothing else.
    static func backOut(_ title: String, identifier: String) -> ConfirmationChoice {
        ConfirmationChoice(title: title, identifier: identifier, style: .plain)
    }
}

extension View {
    /// Shows a confirmation card while `isPresented` is true. The chosen action runs once
    /// the card has closed, so it can dismiss or navigate away from the presenting view.
    func confirmationCard<Details: View>(
        isPresented: Binding<Bool>, card: @escaping () -> ConfirmationCard<Details>
    ) -> some View {
        modifier(ConfirmationCardPresenter(isPresented: isPresented, card: card))
    }

    /// Shows a confirmation card about `item` while it is set, and clears it when the card
    /// closes. The card keeps showing the item while it slides away. Prefer this when the
    /// card depends on state set as it opens: a sheet's content can see an earlier value of
    /// state that `body` itself never reads.
    func confirmationCard<Item: Equatable, Details: View>(
        item: Binding<Item?>, card: @escaping (Item) -> ConfirmationCard<Details>
    ) -> some View {
        modifier(ConfirmationCardItemPresenter(item: item, card: card))
    }
}

private struct ConfirmationCardItemPresenter<Item: Equatable, Details: View>: ViewModifier {
    @Binding var item: Item?
    let card: (Item) -> ConfirmationCard<Details>
    /// The item the card shows, kept after `item` is cleared.
    @State private var shown: Item?

    func body(content: Content) -> some View {
        let isPresented = Binding(get: { item != nil }, set: { if !$0 { item = nil } })
        content
            .confirmationCard(isPresented: isPresented) {
                // `shown` is set before the sheet first asks for its content.
                card((item ?? shown)!)
            }
            .onChange(of: item, initial: true) {
                if let item { shown = item }
            }
    }
}

private struct ConfirmationCardPresenter<Details: View>: ViewModifier {
    @Binding var isPresented: Bool
    let card: () -> ConfirmationCard<Details>
    /// The chosen action, run when the sheet has gone.
    @State private var pending: (() -> Void)?
    /// The card's measured height, so the sheet is as tall as its content.
    @State private var height: CGFloat = 340

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: $isPresented,
            onDismiss: {
                let action = pending
                pending = nil
                action?()
            }
        ) {
            // At accessibility text sizes the card can be taller than the screen: the
            // detent stops at the largest height and the content scrolls.
            ScrollView {
                ConfirmationCardView(card: card()) { choice in
                    pending = choice.action
                    isPresented = false
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .presentationDetents([.height(height)])
            .presentationDragIndicator(.visible)
            // Solid, so what is behind (a map, say) never tints the text.
            .presentationBackground(Color(.systemBackground))
        }
    }
}

private struct ConfirmationCardView<Details: View>: View {
    let card: ConfirmationCard<Details>
    let choose: (ConfirmationChoice) -> Void
    @ScaledMetric(relativeTo: .title2) private var iconSize = 52.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: card.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(card.tint)
                .frame(width: iconSize, height: iconSize)
                .background(card.tint.opacity(0.15), in: .circle)
                .accessibilityHidden(true)
                .padding(.bottom, 14)
            Text(card.title)
                .font(.title3.weight(.bold))
                .fontDesign(.rounded)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(4)
                .accessibilityIdentifier("confirmation.title")
            card.details
                .padding(.top, 12)
                .accessibilitySortPriority(2)
            Text(card.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                // VoiceOver reads what happens before what it happens to.
                .accessibilitySortPriority(3)
                .accessibilityIdentifier("confirmation.message")
            VStack(spacing: 10) {
                button(card.top)
                button(card.bottom)
            }
            .padding(.top, 22)
            .accessibilitySortPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func button(_ choice: ConfirmationChoice) -> some View {
        Button {
            choose(choice)
        } label: {
            Text(choice.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
        .buttonStyle(ConfirmationButtonStyle(style: choice.style))
        .accessibilityIdentifier(choice.identifier)
    }
}

private struct ConfirmationButtonStyle: ButtonStyle {
    let style: ConfirmationChoice.Style

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        switch style {
        // System background on the accent: white on petrol, black on the dark-mode petrol.
        case .prominent: Color(.systemBackground)
        case .destructive: .white
        case .plain: .primary
        case .caution: Self.caution
        }
    }

    private var background: Color {
        switch style {
        case .destructive: Self.destructive
        case .prominent: .accentColor
        case .plain, .caution: Color(.tertiarySystemFill)
        }
    }

    /// Red deep enough for white text at 4.5:1 in both modes.
    private static let destructive = dynamic(light: 0xC4303A, dark: 0xD7261E)
    /// Orange that keeps 4.5:1 on the grey button in both modes.
    private static let caution = dynamic(light: 0x9A4A00, dark: 0xFF9F0A)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
}
