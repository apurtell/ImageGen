import AppKit
import ImageIO
import SwiftUI

struct ZoomableImageView: NSViewRepresentable {
  let image: ViewerImage
  let thumbnails: ThumbnailService
  /// Indicates whether this page is selected, controlling full resolution decoding and zoom state resets.
  let isCurrent: Bool
  /// Unused on macOS; maintained for cross-platform protocol alignment.
  let onSingleTap: () -> Void
  /// Unused on macOS; dismissal is managed via window controls.
  let onDismiss: () -> Void

  @Environment(\.viewerKeyRouter) private var router

  func makeNSView(context: Context) -> ZoomingScrollView {
    let view = ZoomingScrollView(pixelSize: CGSize(width: image.item.pixelWidth, height: image.item.pixelHeight))
    view.dragFile = image.item.file
    context.coordinator.loadThumbnail(image, into: view, thumbnails: thumbnails)
    context.coordinator.setCurrent(isCurrent, image, view: view)
    return view
  }

  func updateNSView(_ view: ZoomingScrollView, context: Context) {
    if isCurrent {
      router?.zoom = { [weak view] in view?.apply($0) }
    } else {
      view.resetZoom()
    }
    context.coordinator.setCurrent(isCurrent, image, view: view)
  }

  /// Cancels pending decode tasks upon view dismantlement.
  static func dismantleNSView(_ view: ZoomingScrollView, coordinator: Coordinator) {
    coordinator.thumbnailTask?.cancel()
    coordinator.fullTask?.cancel()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Coordinates progressive image loading by fetching thumbnails before decoding full resolution
  /// assets.
  @MainActor
  final class Coordinator {
    var thumbnailTask: Task<Void, Never>?
    var fullTask: Task<Void, Never>?
    private var hasFull = false

    func loadThumbnail(_ image: ViewerImage, into view: ZoomingScrollView, thumbnails: ThumbnailService) {
      let url = image.item.url
      let id = image.item.id
      thumbnailTask = Task { [weak view] in
        guard let thumb = await thumbnails.thumbnail(for: url, id: id, px: ThumbnailService.bubbleSize) else { return }
        view?.show(thumb, orientation: 1, isFull: false)
      }
    }

    func setCurrent(_ isCurrent: Bool, _ image: ViewerImage, view: ZoomingScrollView) {
      guard !hasFull else { return }
      if !isCurrent {
        fullTask?.cancel()
        fullTask = nil
        return
      }
      guard fullTask == nil else { return }
      let url = image.item.url
      let id = image.item.id
      fullTask = Task { [weak view, weak self] in
        let decoded = await FullDecoder.shared.decode(url: url, id: id)
        guard !Task.isCancelled, let decoded else { return }
        self?.hasFull = true
        view?.show(decoded.cgImage, orientation: decoded.exifOrientation, isFull: true)
      }
    }
  }
}

/// Tiled layer rendering a `CGImage` with orientation adjustments and bounds fitting.
final class TiledImageLayer: CATiledLayer {
  private struct Content: Sendable {
    var image: CGImage?
    var orientation = 1
  }

  private let content: Locked<Content>

  override init() {
    content = Locked(Content())
    super.init()
    configure()
  }

  override init(layer: Any) {
    content = Locked((layer as? TiledImageLayer)?.content.value ?? Content())
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private func configure() {
    tileSize = CGSize(width: 512, height: 512)
    levelsOfDetail = 5
    levelsOfDetailBias = 3
  }

  func setImage(_ image: CGImage, orientation: Int) {
    content.withLock { $0 = Content(image: image, orientation: orientation) }
    setNeedsDisplay()
  }

  override func draw(in ctx: CGContext) {
    let current = content.value
    guard let image = current.image else { return }
    let stored = CGSize(width: image.width, height: image.height)
    let shown = ExifOrientation.displaySize(stored, orientation: current.orientation)
    ctx.interpolationQuality = .high
    // Uniform aspect-fit scaling centered within bounds.
    let scale = min(bounds.width / shown.width, bounds.height / shown.height)
    ctx.translateBy(x: (bounds.width - shown.width * scale) / 2, y: (bounds.height - shown.height * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.concatenate(ExifOrientation.transform(orientation: current.orientation, size: stored))
    ctx.draw(image, in: CGRect(origin: .zero, size: stored))
  }
}

/// Scroll view document view backed by a `TiledImageLayer`.
final class TiledImageView: NSView {
  init(size: CGSize) {
    super.init(frame: CGRect(origin: .zero, size: size))
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func makeBackingLayer() -> CALayer { TiledImageLayer() }

  func setImage(_ image: CGImage, orientation: Int) {
    (layer as? TiledImageLayer)?.setImage(image, orientation: orientation)
  }
}

/// Clip view constraining content bounds to center the document when smaller than the viewport.
final class CenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposed)
    guard let document = documentView else { return rect }
    let inset = ZoomMath.centeringInsets(content: document.frame.size, bounds: rect.size)
    if inset.horizontal > 0 { rect.origin.x = document.frame.minX - inset.horizontal }
    if inset.vertical > 0 { rect.origin.y = document.frame.minY - inset.vertical }
    return rect
  }
}

/// Scroll view managing image panning, magnification gestures, and file dragging.
///
/// Maps document points to image pixels so magnification reflects on-screen display scale.
@MainActor
final class ZoomingScrollView: NSScrollView {
  private let canvas: TiledImageView
  private let pixelSize: CGSize
  private var hasFull = false
  private var lastBounds = CGSize.zero
  /// Exportable image file referenced by drag operations.
  var dragFile: ImageFile?
  fileprivate var didStartDrag = false

  init(pixelSize: CGSize) {
    self.pixelSize = CGSize(width: max(pixelSize.width, 1), height: max(pixelSize.height, 1))
    canvas = TiledImageView(size: self.pixelSize)
    super.init(frame: .zero)
    let clip = CenteringClipView()
    clip.drawsBackground = false
    contentView = clip
    documentView = canvas
    drawsBackground = false
    hasHorizontalScroller = false
    hasVerticalScroller = false
    allowsMagnification = true
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Image, \(Int(self.pixelSize.width)) by \(Int(self.pixelSize.height))")
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Updates displayed image content, ignoring thumbnail updates once a full resolution image is
  /// loaded.
  func show(_ image: CGImage, orientation: Int, isFull: Bool) {
    if hasFull && !isFull { return }
    hasFull = hasFull || isFull
    canvas.setImage(image, orientation: orientation)
  }

  private var fitScale: CGFloat { ZoomMath.fitScale(image: pixelSize, bounds: bounds.size) }
  private var screenScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
  /// Magnification scale where image pixels map 1:1 to backing pixels.
  private var actualScale: CGFloat { 1 / max(screenScale, 1) }
  private var isAtFit: Bool { magnification <= minMagnification + 0.0001 }

  override func layout() {
    super.layout()
    guard bounds.size != lastBounds, bounds.width > 0, bounds.height > 0 else { return }
    let wasAtFit = lastBounds == .zero || isAtFit
    lastBounds = bounds.size
    minMagnification = fitScale
    maxMagnification = ZoomMath.maxScale(fit: fitScale, screenScale: screenScale)
    if wasAtFit || magnification < minMagnification {
      magnification = minMagnification
      recenter()
    }
  }

  /// Updates maximum magnification constraints when display scale factors change.
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard bounds.width > 0, bounds.height > 0 else { return }
    maxMagnification = ZoomMath.maxScale(fit: fitScale, screenScale: screenScale)
    if magnification > maxMagnification { magnification = maxMagnification }
  }

  /// Centers the document within the clip view viewport.
  private func recenter() {
    let size = contentView.bounds.size
    let origin = CGPoint(x: canvas.frame.midX - size.width / 2, y: canvas.frame.midY - size.height / 2)
    contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: origin, size: size)).origin)
    reflectScrolledClipView(contentView)
  }

  /// Resets magnification to minimum fit scale without animation.
  func resetZoom() {
    guard !isAtFit else { return }
    magnification = minMagnification
    recenter()
  }

  func apply(_ command: ZoomCommand) {
    let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    switch command {
    case .zoomIn: zoom(to: ZoomMath.stepped(magnification, zoomingIn: true, fit: minMagnification, maxScale: maxMagnification), at: center)
    case .zoomOut: zoom(to: ZoomMath.stepped(magnification, zoomingIn: false, fit: minMagnification, maxScale: maxMagnification), at: center)
    case .fit: zoom(to: minMagnification, at: CGPoint(x: canvas.frame.midX, y: canvas.frame.midY))
    case .actualSize: zoom(to: min(max(actualScale, minMagnification), maxMagnification), at: center)
    }
  }

  private func zoom(to scale: CGFloat, at point: CGPoint) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      animator().setMagnification(scale, centeredAt: point)
    }
  }

  override func mouseDown(with event: NSEvent) {
    didStartDrag = false
    guard event.clickCount == 2 else { return super.mouseDown(with: event) }
    let point = canvas.convert(event.locationInWindow, from: nil)
    let target = ZoomMath.toggleTarget(current: magnification, fit: minMagnification, actual: actualScale, maxScale: maxMagnification)
    zoom(to: target, at: target <= minMagnification ? CGPoint(x: canvas.frame.midX, y: canvas.frame.midY) : point)
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isAtFit else { return startDragOut(event) }
    let origin = contentView.bounds.origin
    contentView.scroll(to: CGPoint(x: origin.x - event.deltaX / magnification, y: origin.y + event.deltaY / magnification))
    reflectScrolledClipView(contentView)
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 20
    let scale = min(max(magnification * (1 + delta), minMagnification), maxMagnification)
    setMagnification(scale, centeredAt: canvas.convert(event.locationInWindow, from: nil))
  }
}

extension ZoomingScrollView: NSDraggingSource {
  /// Initiates an AppKit drag session with a copy of the image file when dragged while zoomed to fit.
  private func startDragOut(_ event: NSEvent) {
    guard !didStartDrag, let dragFile, let url = try? ExportScratch.namedCopy(of: dragFile.url, name: dragFile.suggestedName) else { return }
    didStartDrag = true
    let item = NSDraggingItem(pasteboardWriter: url as NSURL)
    let point = convert(event.locationInWindow, from: nil)
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    item.setDraggingFrame(CGRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64), contents: icon)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    .copy
  }
}
