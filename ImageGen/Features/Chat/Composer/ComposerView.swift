import SwiftUI

extension Glass {
  /// High opacity glass styling calibrated for small composer controls (pills, chips) to maintain
  /// text legibility against complex imagery scrolling beneath the translucent floating panel.
  /// Evaluates color scheme values to ensure reliable dynamic light/dark mode adaptation.
  static func composerControl(_ scheme: ColorScheme) -> Glass {
    .regular.tint(scheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.85))
  }
}

/// Root composer view orchestrating context chips, attachment staging trays, parameter pills,
/// and primary text input controls within a cohesive translucent floating surface.
struct ComposerView: View {
  let model: ChatScreenModel

  var body: some View {
    // Coalesce neighboring glass elements into a continuous translucent container hierarchy.
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
