import SwiftUI

/// The composer (D§3.5): chips, the attachment tray, pills and the input row, in a glass container.
///
/// The composer's views share the chat screen's `ChatScreenModel`; they read its state and call
/// its methods, and keep only presentation state of their own (which picker is open, focus). A
/// plain `let model` is enough to read an `@Observable` object and redraw on its changes; only a
/// view that needs a two-way `$` binding to a property uses `@Bindable` (`ComposerInputRow`).
extension Glass {
  /// Glass for the composer's small controls (pills, chips), tinted nearly solid white (light
  /// appearance) or black (dark), so their labels stay legible over an image scrolling under the
  /// composer (M10: clear glass was hard to read there). Opacity can't do this: it has no effect on
  /// glass inside a `GlassEffectContainer`, so the tint makes the glass itself more solid. The caller
  /// passes its `colorScheme`: a dynamic system color in a glass tint keeps the appearance it had when
  /// first drawn, so it wouldn't follow a switch between light and dark.
  static func composerControl(_ scheme: ColorScheme) -> Glass {
    .regular.tint(scheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.85))
  }
}

struct ComposerView: View {
  let model: ChatScreenModel

  var body: some View {
    // The container lets nearby glass shapes (pills, buttons) blend into each other as one surface.
    GlassEffectContainer(spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        if model.flashUnlisted {
          Label(OnboardingModel.flashWarning, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
            .accessibilityLabel("Warning: \(OnboardingModel.flashWarning)")
        }
        ContextChips(model: model)
        AttachmentTray(model: model)
        SettingsPills(model: model)
        ComposerInputRow(model: model)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .toast(model.toast, offset: -44)
  }
}
