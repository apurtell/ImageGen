import SwiftData
import SwiftUI

/// Renders conversational context indicator chips above the composer, displaying pinned image
/// references or implicit prior turn edit continuity indicators alongside dismissal actions.
struct ContextChips: View {
  let model: ChatScreenModel
  @Environment(\.modelContext) private var context
  @Environment(\.colorScheme) private var colorScheme

  private func asset(_ id: UUID?) -> ImageAsset? {
    guard let id else { return nil }
    // Gracefully resolve entity lookup errors to nil to display fallback thumbnail placeholders.
    return try? context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { $0.id == id })).first
  }

  var body: some View {
    if model.showsPinChip {
      HStack(spacing: 8) {
        SquareThumbnail(asset: asset(model.pinnedImageID), size: 28, corner: 6)
          .opacity(model.pinChipDimmed ? 0.4 : 1)
        Text(model.pinChipDimmed ? "Pinned image replaced by attachments" : "Editing from pinned image")
          .font(.footnote)
          .foregroundStyle(model.pinChipDimmed ? .secondary : .primary)
        Button {
          Task { await model.unpin() }
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .accessibilityLabel("Unpin")
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      // Apply dimming directly to subview content to bypass container-level glass compositing constraints.
      .glassEffect(.composerControl(colorScheme))
    } else if model.showsImplicitChip {
      HStack(spacing: 8) {
        SquareThumbnail(asset: asset(model.implicitBaseID), size: 28, corner: 6)
        Text("Editing latest image").font(.footnote)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .glassEffect(.composerControl(colorScheme))
      .accessibilityElement(children: .combine)
    }
  }
}
