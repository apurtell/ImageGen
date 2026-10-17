import SwiftUI

/// Horizontal scroll container presenting staged input image attachments in dispatch order,
/// displaying progress indicators, error diagnostics, reordering controls, and capacity captions.
struct AttachmentTray: View {
  let model: ChatScreenModel

  var body: some View {
    if !model.tray.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            // Preserve child view state across list reordering and deletions via stable entity identifiers.
            ForEach(Array(model.tray.enumerated()), id: \.element.id) { index, item in
              TrayThumbnail(model: model, item: item, index: index, count: model.tray.count)
            }
          }
        }
        Text(model.trayCaption)
          .font(.caption)
          .foregroundStyle(model.trayCounts.failed > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          .accessibilityLabel("Attachments: \(model.trayCaption)")
      }
    }
  }
}

/// Individual thumbnail cell rendering staged preview graphics, progress indicators, removal badges,
/// and context actions for an attachment candidate.
private struct TrayThumbnail: View {
  let model: ChatScreenModel
  let item: TrayItem
  let index: Int
  let count: Int
  @State private var image: CGImage?
  @State private var showFailure = false

  var body: some View {
    ZStack {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFill()
      } else {
        Rectangle().fill(.quaternary)
      }
      if item.isPending {
        Rectangle().fill(.black.opacity(0.25))
        ProgressView().tint(.white)
      } else if item.failure != nil {
        Rectangle().fill(.black.opacity(0.35))
        Button {
          showFailure = true
        } label: {
          Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.yellow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Couldn't prepare this image")
      }
    }
    .frame(width: 56, height: 56)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    // Constrain badge tap targets within bounds to avoid clip-path interference in scroll views.
    .overlay(alignment: .topTrailing) {
      Button {
        model.removeTrayItem(item.id)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.6))
          .font(.system(size: 18))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove image \(index + 1)")
    }
    .contextMenu {
      Button("Move Left", systemImage: "arrow.left") { model.moveTrayItem(item.id, by: -1) }
        .disabled(index == 0)
      Button("Move Right", systemImage: "arrow.right") { model.moveTrayItem(item.id, by: 1) }
        .disabled(index == count - 1)
      Button("Remove", systemImage: "trash", role: .destructive) { model.removeTrayItem(item.id) }
    }
    .alert("Couldn't prepare this image", isPresented: $showFailure) {
      Button("Remove", role: .destructive) { model.removeTrayItem(item.id) }
      Button("Keep", role: .cancel) {}
    } message: {
      Text(item.failure ?? "")
    }
    // Generate preview imagery directly from staged originals, reacting to URI resolution during import tasks.
    .task(id: item.originalURL) {
      guard let url = item.originalURL else { return }
      image = await model.services.thumbnails.thumbnail(for: url, id: item.id, px: 168)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Image \(index + 1) of \(count)")
  }
}
