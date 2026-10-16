import SwiftUI

/// The composer (D§3.5): chips, the attachment tray, pills and the input row, in a glass container.
struct ComposerView: View {
  let model: ChatScreenModel

  var body: some View {
    GlassEffectContainer(spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        ContextChips(model: model)
        AttachmentTray(model: model)
        SettingsPills(model: model)
        ComposerInputRow(model: model)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .overlay(alignment: .top) {
      if let toast = model.toast {
        Text(toast)
          .font(.footnote)
          .padding(.horizontal, 14).padding(.vertical, 8)
          .glassEffect()
          .offset(y: -44)
          .transition(.opacity)
          .accessibilityAddTraits(.isStaticText)
      }
    }
    .animation(.default, value: model.toast)
  }
}
