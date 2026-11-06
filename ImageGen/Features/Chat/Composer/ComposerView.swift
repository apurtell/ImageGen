import SwiftUI

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
            .font(Platform.composerControlFont)
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
