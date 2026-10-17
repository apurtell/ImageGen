import SwiftUI

/// The Model, Aspect and Resolution pills (D§3.5): an accent dot on an override, ⚠︎ on coercion.
///
/// Each item starts a `Task` that saves the override; the pill's label changes when the save
/// completes and the model's `overrides` changes. The checkmark marks the effective value, which
/// can differ from the override when the model coerces it.
struct SettingsPills: View {
  let model: ChatScreenModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // Wraps whole pills to a new row at large text sizes, instead of breaking their labels.
    FlowLayout(spacing: 8) {
      Menu {
        Button(model.defaultModelItemLabel) { Task { await model.setModel(nil, from: .pill) } }
        Divider()
        ForEach(model.menuModels) { m in
          Button { Task { await model.setModel(m.id, from: .pill) } } label: {
            if model.effective.modelID == m.id { Label(m.shortName, systemImage: "checkmark") } else { Text(m.shortName) }
          }
        }
      } label: {
        pill(model.modelPillLabel, dot: model.modelOverridden, caution: model.isCoerced(.model))
      }
      .accessibilityLabel("Model \(model.modelPillLabel)")
      .menuOrder(.fixed)

      Menu {
        Button(model.defaultAspectItemLabel) { Task { await model.setAspect(nil, from: .pill) } }
        ForEach(model.aspectSections, id: \.group) { section in
          Section(section.group.rawValue.capitalized) {
            ForEach(section.ratios, id: \.self) { r in
              Button { Task { await model.setAspect(r, from: .pill) } } label: {
                if model.effective.aspectRatio == r { Label(r.rawValue, systemImage: "checkmark") } else { Text(r.rawValue) }
              }
            }
          }
        }
      } label: {
        pill(model.aspectPillLabel, dot: model.aspectOverridden, caution: model.isCoerced(.aspectRatio))
      }
      .accessibilityLabel("Aspect ratio \(model.aspectPillLabel)")
      .menuOrder(.fixed)

      Menu {
        // Some models take no size parameter.
        if model.sizes.isEmpty {
          Text("Fixed by this model")
        } else {
          Button(model.defaultSizeItemLabel) { Task { await model.setSize(nil, from: .pill) } }
          Divider()
          ForEach(model.sizes, id: \.self) { s in
            Button { Task { await model.setSize(s, from: .pill) } } label: {
              if model.effective.imageSize == s { Label(s.displayName, systemImage: "checkmark") } else { Text(s.displayName) }
            }
          }
        }
      } label: {
        pill(model.sizePillLabel, dot: model.sizeOverridden, caution: model.isCoerced(.imageSize))
      }
      .accessibilityLabel("Resolution \(model.sizePillLabel)")
      .menuOrder(.fixed)
    }
    // A menu's label takes the button tint (the accent color) over its own foreground style; the
    // primary tint makes the labels black on light and white on dark, legible over any image.
    .tint(.primary)
  }

  private func pill(_ text: String, dot: Bool, caution: Bool) -> some View {
    HStack(spacing: 4) {
      if dot { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
      // Black on light, white on dark (`.primary`), not the accent color: legible over any image.
      Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).fixedSize()
      if caution { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.primary)
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .glassEffect(.composerControl(colorScheme).interactive(), in: .capsule)
  }
}
