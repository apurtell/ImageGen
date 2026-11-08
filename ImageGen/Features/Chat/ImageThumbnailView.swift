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
  /// Enables adaptive multi-resolution thumbnail fetching based on rendered viewport size.
  var followsDisplayedSize = false
  @Environment(\.displayScale) private var displayScale
  /// Spatial proximity flag indicating whether an offscreen row is near the visible viewport, used to evict unrendered image memory in non-lazy layouts.
  @Environment(\.transcriptRowPresence) private var presence
  @State private var image: CGImage?
  @State private var sharper: SharperImage?
  /// Quantized target thumbnail dimensions derived from active display geometry.
  @State private var wantedPx: Int?

  /// High-resolution thumbnail image scaled to active display bounds; purged when scrolled away to respect memory limits.
  private struct SharperImage {
    let imageID: UUID
    let px: Int
    let image: CGImage
  }

  private var isWanted: Bool { presence?.isNear ?? true }

  /// Debounce interval before initiating thumbnail decodes during continuous view resizing.
  private static let sharpenDelay: Duration = .milliseconds(250)

  private var shownImage: CGImage? {
    if let sharper, sharper.imageID == imageID { sharper.image } else { image }
  }

  var aspect: CGFloat { pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 1 }

  var body: some View {
    ZStack {
      if let image = shownImage {
        Image(decorative: image, scale: 1)
          .resizable()
          .aspectRatio(contentMode: contentMode)
          // Maintain fixed container aspect geometry regardless of pixel decoding state to prevent layout reflow shifts during scroll.
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Rectangle()
          .fill(.quaternary)
          .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
      }
    }
    .aspectRatio(aspect, contentMode: contentMode)
    .onGeometryChange(for: Int.self) { [displayScale, followsDisplayedSize, px, pixelWidth, pixelHeight] geometry in
      followsDisplayedSize
        ? ThumbnailService.displayPixels(
          displayed: geometry.size, scale: displayScale, originalLongEdge: max(pixelWidth, pixelHeight))
        : px
    } action: { wantedPx = $0 }
    .task(id: "\(imageID)-\(px)-\(isWanted)") {
      guard isWanted else { image = nil; return }
      let loaded = await env.thumbnails.thumbnail(for: env.files.url(relative: relativePath), id: imageID, px: px)
      if !Task.isCancelled { image = loaded }
    }
    .task(id: "\(imageID)-\(wantedPx ?? px)-\(isWanted)") {
      guard isWanted else { sharper = nil; return }
      await loadSharper()
    }
    .onDisappear { sharper = nil }
    .accessibilityLabel("Image")
  }

  /// Asynchronously requests thumbnails matched to target resolution, retaining current display contents until the decode completes.
  private func loadSharper() async {
    guard let wanted = wantedPx, wanted > px || sharper != nil else { return }
    // Avoid downscale decoding if currently loaded image dimensions satisfy target requirements.
    if let sharper, sharper.imageID == imageID, sharper.px >= wanted, wanted > px { return }
    let thumbnails = env.thumbnails
    let longEdge = max(pixelWidth, pixelHeight)
    if wanted > px, let hit = thumbnails.cachedThumbnail(id: imageID, atLeast: wanted, originalLongEdge: longEdge) {
      sharper = SharperImage(imageID: imageID, px: hit.px, image: hit.image)
      return
    }
    do { try await Task.sleep(for: Self.sharpenDelay) } catch { return }
    guard wanted > px else {
      sharper = nil
      return
    }
    let loaded = await thumbnails.thumbnail(for: env.files.url(relative: relativePath), id: imageID, px: wanted)
    if !Task.isCancelled, let loaded { sharper = SharperImage(imageID: imageID, px: wanted, image: loaded) }
  }
}

extension ImageThumbnailView {
  init(
    asset: ImageAsset, px: Int = ThumbnailService.bubbleSize, contentMode: ContentMode = .fit,
    followsDisplayedSize: Bool = false
  ) {
    self.init(
      imageID: asset.id, relativePath: asset.relativePath, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
      px: px, contentMode: contentMode, followsDisplayedSize: followsDisplayedSize)
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
