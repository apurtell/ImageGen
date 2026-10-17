import SwiftUI

/// Modal presentation for configuring per-conversation generation parameter overrides.
///
/// Dispatches asynchronous update tasks through `ChatScreenModel` when user selections diverge from global defaults.
struct ChatSettingsSheet: View {
  let model: ChatScreenModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Picker("Model", selection: Binding(get: { model.overrides.modelID }, set: { v in Task { await model.setModel(v, from: .chatSettings) } })) {
          Text(model.defaultModelItemLabel).tag(String?.none)
          ForEach(model.menuModels) { m in Text(m.shortName).tag(Optional(m.id)) }
        }
        Picker("Aspect ratio", selection: Binding(get: { model.overrides.aspectRatio }, set: { v in Task { await model.setAspect(v, from: .chatSettings) } })) {
          Text(model.defaultAspectItemLabel).tag(AspectRatio?.none)
          ForEach(model.aspectSections, id: \.group) { section in
            ForEach(section.ratios, id: \.self) { r in Text(r.rawValue).tag(Optional(r)) }
          }
        }
        Picker("Resolution", selection: Binding(get: { model.overrides.imageSize }, set: { v in Task { await model.setSize(v, from: .chatSettings) } })) {
          Text(model.defaultSizeItemLabel).tag(ImageSize?.none)
          ForEach(model.sizes, id: \.self) { s in Text(s.displayName).tag(Optional(s)) }
        }
      }
      .navigationTitle("Chat Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}
