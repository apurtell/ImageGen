import SwiftUI

/// The attachment tray (D§3.5): 56 pt thumbnails in send order, each with ✕, a spinner while
/// importing or preparing, ⚠︎ on failure (tap for the reason and Remove), and a long-press menu;
/// then the caption with the count and budget, or why Send is blocked.
struct AttachmentTray: View {
  let model: ChatScreenModel

  var body: some View {
    if !model.tray.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
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
    // Inside the thumbnail's bounds: an offset badge hung outside the tray's scroll view and
    // didn't receive taps.
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
    .task(id: item.originalURL) {
      guard let url = item.originalURL else { return }
      image = await model.services.thumbnails.thumbnail(for: url, id: item.id, px: 168)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Image \(index + 1) of \(count)")
  }
}
