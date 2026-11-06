import ImageIO
import SwiftUI

/// Displays the image scaled to fit without zoom or drag gestures on macOS.
struct ZoomableImageView: View {
  let image: ViewerImage
  let thumbnails: ThumbnailService
  let isCurrent: Bool
  let onSingleTap: () -> Void
  let onDismiss: () -> Void

  @State private var picture: CGImage?

  var body: some View {
    Group {
      if let picture {
        Image(decorative: picture, scale: 1).resizable().scaledToFit()
      } else {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture(perform: onSingleTap)
    .task(id: image.item.id) {
      picture = await thumbnails.thumbnail(for: image.item.url, id: image.item.id, px: ThumbnailService.bubbleSize)
    }
  }
}
