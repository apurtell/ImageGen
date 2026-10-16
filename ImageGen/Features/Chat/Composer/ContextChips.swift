import SwiftData
import SwiftUI

/// The pin chip (with ✕) and the informational "Editing latest image" chip (no ✕) (D§3.5).
struct ContextChips: View {
  let model: ChatScreenModel
  @Environment(\.modelContext) private var context

  private func asset(_ id: UUID?) -> ImageAsset? {
    guard let id else { return nil }
    return try? context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { $0.id == id })).first
  }

  var body: some View {
    if model.showsPinChip {
      HStack(spacing: 8) {
        SquareThumbnail(asset: asset(model.pinnedImageID), size: 28, corner: 6)
        Text(model.pinChipDimmed ? "Pinned image replaced by attachments" : "Editing from pinned image")
          .font(.footnote)
        Button {
          Task { await model.unpin() }
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .accessibilityLabel("Unpin")
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .glassEffect()
      .opacity(model.pinChipDimmed ? 0.5 : 1)
    } else if model.showsImplicitChip {
      HStack(spacing: 8) {
        SquareThumbnail(asset: asset(model.implicitBaseID), size: 28, corner: 6)
        Text("Editing latest image").font(.footnote)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .glassEffect()
      .accessibilityElement(children: .combine)
    }
  }
}
