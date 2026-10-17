import SwiftUI

/// Asynchronously renders cached image thumbnails via `ThumbnailService`, reserving geometry based on known aspect ratios.
struct ImageThumbnailView: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  private var env: AppEnvironment { environment ?? AppEnvironment.shared }
  let imageID: UUID
  let relativePath: String
  let pixelWidth: Int
  let pixelHeight: Int
  var px = ThumbnailService.bubbleSize
  var contentMode: ContentMode = .fit
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

/// Compact square thumbnail component utilized within message rows, selection chips, and metadata cards.
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
