import SwiftUI

/// Keep AppKit-backed button behavior (keyboard activation, roles and pressed state),
/// adding the same non-layout-changing hover treatment to each visual variant.
/// Native Menu/contextMenu actions must reset to .automatic; inheriting this
/// primitive style prevents AppKit from constructing actionable menu items.
struct VaultButtonStyle: PrimitiveButtonStyle {
  enum Kind { case secondary, primary, plain, row }
  var kind: Kind = .secondary

  init(_ kind: Kind = .secondary) { self.kind = kind }

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    Group {
      switch kind {
      case .primary:
        Button(configuration).buttonStyle(.borderedProminent)
      case .secondary:
        Button(configuration).buttonStyle(.bordered)
      case .plain, .row:
        Button(configuration).buttonStyle(.plain)
      }
    }
    .modifier(
      VaultHoverFeedback(
        primary: kind == .primary,
        destructive: configuration.role == .destructive,
        radius: kind == .row ? 9 : 5))
  }
}

private struct VaultHoverFeedback: ViewModifier {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  var primary = false
  var destructive = false
  var radius: CGFloat = 5

  private var active: Bool { enabled && hovering }
  private var color: Color { destructive ? .red : Palette.accent }

  func body(content: Content) -> some View {
    content
      .overlay {
        RoundedRectangle(cornerRadius: radius)
          .fill(primary ? Color.black.opacity(active ? 0.09 : 0) : color.opacity(active ? 0.07 : 0))
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius)
          .strokeBorder((primary ? Color.white : color).opacity(active ? 0.5 : 0), lineWidth: 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .onHover { hovering = $0 }
      .onDisappear { hovering = false }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
  }
}

extension View {
  /// Menus and links retain their own native behavior; decorate only the trigger.
  func vaultHoverFeedback() -> some View { modifier(VaultHoverFeedback()) }
}
