import SwiftUI

/// Flow wrapping pill controls displaying model selection, aspect ratio, and resolution overrides,
/// complete with visual override indicators, coercion warnings, and hierarchical selection menus.
struct SettingsPills: View {
  let model: ChatScreenModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // Flow layout adapts capsule pills to multi-line wrapping during Dynamic Type scaling without truncating labels.
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
        // Models with fixed internal output resolutions omit configurable dimension selections.
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
    // Force primary tinting across menu labels to override accent tint inheritance, maximizing contrast over underlying content.
    .tint(.primary)
  }

  private func pill(_ text: String, dot: Bool, caution: Bool) -> some View {
    HStack(spacing: 4) {
      if dot { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
      // Utilize high-contrast primary foreground styling to maintain legibility across varying backdrop imagery.
      Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).fixedSize()
      if caution { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
      Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.primary)
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .glassEffect(.composerControl(colorScheme).interactive(), in: .capsule)
  }
}
