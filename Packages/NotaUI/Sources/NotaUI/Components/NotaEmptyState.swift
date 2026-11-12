import SwiftUI

/// An empty library section, search or panel: a Nota icon on an ink-tinted disc, a title, one line of
/// guidance and an optional action.
///
/// ```swift
/// NotaEmptyState(.star, title: "No Favorites",
///                message: "Favorite a note from its menu to keep it here.")
/// ```
public struct NotaEmptyState<Actions: View>: View {
    let icon: NotaIcon
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actions: Actions

    public init(_ icon: NotaIcon, title: LocalizedStringKey, message: LocalizedStringKey,
                @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: NotaSpacing.l) {
            NotaIconView(icon, size: 28)
                .foregroundStyle(NotaColor.textInk)
                .frame(width: 64, height: 64)
                .background(NotaColor.bgInkTint, in: Circle())
            VStack(spacing: NotaSpacing.xs) {
                Text(title)
                    .font(NotaFont.title3)
                    .foregroundStyle(NotaColor.textPrimary)
                Text(message)
                    .font(NotaFont.subheadline)
                    .foregroundStyle(NotaColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            actions
                .padding(.top, NotaSpacing.xxs)
        }
        .frame(maxWidth: 360)
        .padding(NotaSpacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

public extension NotaEmptyState where Actions == EmptyView {
    init(_ icon: NotaIcon, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(icon, title: title, message: message) { EmptyView() }
    }
}

#Preview {
    NotaEmptyState(.grid, title: "No Notes", message: "Notes you create will appear here.") {
        Button {} label: { NotaButtonLabel("New Note", icon: .plus) }
            .buttonStyle(.nota(.primary))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(NotaColor.bgApp)
}
