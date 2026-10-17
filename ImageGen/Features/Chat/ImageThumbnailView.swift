import SwiftUI

/// An image loaded through `ThumbnailService`, with a placeholder frame sized from the stored pixel
/// dimensions so the layout doesn't jump (D§3.4, D§8).
///
/// The view takes plain values (ID, path, size), not the record, so it works for any image.
/// `ThumbnailService` decodes off the main actor and caches; this view only awaits the result.
struct ImageThumbnailView: View {
  /// Optional: a context menu's preview renders outside the view hierarchy and doesn't inherit it.
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  private var env: AppEnvironment { environment ?? AppEnvironment.shared }
  let imageID: UUID
  let relativePath: String
  let pixelWidth: Int
  let pixelHeight: Int
  var px = ThumbnailService.bubbleSize
  var contentMode: ContentMode = .fit
  /// The decoded thumbnail; nil shows the placeholder.
  @State private var image: CGImage?

  var aspect: CGFloat { pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1 }

  var body: some View {
    ZStack {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .aspectRatio(contentMode: contentMode)
      } else {
        Rectangle()
          .fill(.quaternary)
          .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
      }
    }
    .aspectRatio(aspect, contentMode: contentMode)
    // Loads when the view appears and again if the image or size changes. A row that scrolls out
    // of the lazy stack cancels its load.
    .task(id: "\(imageID)-\(px)") {
      image = await env.thumbnails.thumbnail(for: env.files.url(relative: relativePath), id: imageID, px: px)
    }
    .accessibilityLabel("Image")
  }
}

extension ImageThumbnailView {
  init(asset: ImageAsset, px: Int = ThumbnailService.bubbleSize, contentMode: ContentMode = .fit) {
    self.init(
      imageID: asset.id, relativePath: asset.relativePath, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
      px: px, contentMode: contentMode)
  }
}

/// A small square thumbnail (chat rows, chips, captions).
struct SquareThumbnail: View {
  let asset: ImageAsset?
  let size: CGFloat
  var corner: CGFloat = 8

  var body: some View {
    Group {
      if let asset {
        ImageThumbnailView(asset: asset, px: ThumbnailService.listSize, contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
          .overlay(Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: corner))
  }
}
