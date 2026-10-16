import SwiftUI

/// The Model, Aspect and Resolution pills (D§3.5): an accent dot on an override, ⚠︎ on coercion.
struct SettingsPills: View {
  let model: ChatScreenModel

  var body: some View {
    HStack(spacing: 8) {
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
  }

  private func pill(_ text: String, dot: Bool, caution: Bool) -> some View {
    HStack(spacing: 4) {
      if dot { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
      Text(text).font(.footnote.weight(.medium))
      if caution { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
      Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .glassEffect(.regular.interactive(), in: .capsule)
  }
}
