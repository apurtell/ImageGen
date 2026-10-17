import ImageIO
import OSLog
import SwiftUI
import UIKit

/// Bridge component hosting an interactive UIKit zooming scroll view within SwiftUI paging hierarchies.
///
/// Manages progressive visual staging, transitioning smoothly from an initial downsampled preview to a
/// full resolution decode while supporting pinch gestures, double-tap zoom targets, and interactive downward
/// drag-to-dismiss mechanics. Background decoding requests are prioritized for the currently active page,
/// ensuring low memory pressure and responsive interaction across carousel navigations.
struct ZoomableImageView: UIViewRepresentable {
  let image: ViewerImage
  let thumbnails: ThumbnailService
  /// Indicates whether this page is the active selection, controlling high-resolution decoding triggers and zoom resets.
  let isCurrent: Bool
  let onSingleTap: () -> Void
  let onDismiss: () -> Void

  /// Instantiates and configures the underlying scroll canvas, kicking off initial thumbnail loading.
  func makeUIView(context: Context) -> ZoomingScrollView {
    let view = ZoomingScrollView(pixelSize: CGSize(width: image.item.pixelWidth, height: image.item.pixelHeight))
    view.onSingleTap = onSingleTap
    view.onDismiss = onDismiss
    context.coordinator.loadThumbnail(image, into: view, thumbnails: thumbnails)
    context.coordinator.setCurrent(isCurrent, image, view: view)
    return view
  }

  func updateUIView(_ view: ZoomingScrollView, context: Context) {
    // Update interaction callbacks and reset zoom scale if the view is no longer actively selected.
    view.onSingleTap = onSingleTap
    view.onDismiss = onDismiss
    if !isCurrent { view.resetZoom() }
    context.coordinator.setCurrent(isCurrent, image, view: view)
  }

  /// Cancels in-flight asynchronous decode tasks when the view lifecycle concludes.
  static func dismantleUIView(_ view: ZoomingScrollView, coordinator: Coordinator) {
    coordinator.thumbnailTask?.cancel()
    coordinator.fullTask?.cancel()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Coordinates progressive image pipeline operations and tracks asynchronous decode tasks for the page view.
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
        view?.show(UIImage(cgImage: thumb), isFull: false)
      }
    }

    /// Manages the activation lifecycle for high-resolution asset decoding as page focus changes.
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
        let full = await FullDecoder.shared.decode(url: url, id: id)
        guard !Task.isCancelled, let full else { return }
        self?.hasFull = true
        view?.show(full, isFull: true)
      }
    }
  }
}

/// Serialized background decoder managing full-resolution bitmap rendering and retaining the most recently
/// decoded image to optimize interface orientation transitions without redundant work.
actor FullDecoder {
  static let shared = FullDecoder()
  private var last: (id: UUID, image: UIImage)?

  /// Decodes and returns the full-resolution image from disk, or nil if cancelled or decoding fails.
  func decode(url: URL, id: UUID) -> UIImage? {
    if let last, last.id == id { return last.image }
    guard !Task.isCancelled else { return nil }
    let image = FullDecode.decode(url: url, id: id)
    last = image.map { (id, $0) }
    return image
  }

  /// Purges the cached full-resolution bitmap upon viewer dismissal to reclaim system memory.
  func clear() { last = nil }
}

/// Low-level image decoding utilities executing synchronously off the main actor, mapping EXIF metadata to orientation.
enum FullDecode {
  /// Decodes the primary image bitmap at full resolution with EXIF orientation metadata applied.
  static func decode(url: URL, id: UUID) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, ImageInspector.noCache),
      let info = try? ImageInspector.inspect(source)
    else { return nil }
    // Force immediate decode off the main thread to prevent UI hitches during first presentation.
    let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    guard let cg = DecodeTimer().measure("viewer full \(info.pixelWidth)×\(info.pixelHeight)", { CGImageSourceCreateImageAtIndex(source, 0, options) })
    else { return nil }
    #if DEBUG
      Log.imaging.debug(
        "viewer decode img \(Format.short(id), privacy: .public) \(info.pixelWidth)×\(info.pixelHeight): phys_footprint \(MemoryFootprint.mb(MemoryFootprint.current()), privacy: .public)"
      )
    #endif
    return UIImage(cgImage: cg, scale: 1, orientation: orientation(info.orientation))
  }

  /// Translates standard EXIF orientation integers to corresponding `UIImage.Orientation` cases.
  static func orientation(_ exif: Int) -> UIImage.Orientation {
    switch exif {
    case 2: .upMirrored
    case 3: .down
    case 4: .downMirrored
    case 5: .leftMirrored
    case 6: .right
    case 7: .rightMirrored
    case 8: .left
    default: .up
    }
  }
}

/// Custom scroll canvas managing image zooming, centering, and gesture interactions.
///
/// Implements pinch-to-zoom, double-tap zoom toggling, single-tap chrome toggling, and interactive downward
/// translation to dismiss the full-screen viewer hierarchy.
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  let imageView = UIImageView()
  /// Native pixel dimensions of the target image after orientation transformations.
  private let pixelSize: CGSize
  /// Indicates whether the high-resolution decoded image has been rendered, preventing thumbnail regression.
  private var hasFull = false
  /// Cached container dimensions from the previous layout pass to detect viewport resizes.
  private var lastBounds = CGSize.zero
  private let dismissPan = UIPanGestureRecognizer()
  var onSingleTap: () -> Void = {}
  var onDismiss: () -> Void = {}

  init(pixelSize: CGSize) {
    // Enforce non-zero dimensions to ensure well-defined scale calculations.
    self.pixelSize = CGSize(width: max(pixelSize.width, 1), height: max(pixelSize.height, 1))
    super.init(frame: .zero)
    delegate = self
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    decelerationRate = .fast
    contentInsetAdjustmentBehavior = .never
    backgroundColor = .clear
    imageView.contentMode = .scaleAspectFit
    imageView.frame = CGRect(origin: .zero, size: self.pixelSize)
    addSubview(imageView)
    contentSize = self.pixelSize

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    addGestureRecognizer(doubleTap)
    let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
    // Prevent chrome toggle conflict when initiating double-tap zoom interactions.
    singleTap.require(toFail: doubleTap)
    addGestureRecognizer(singleTap)
    dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
    dismissPan.delegate = self
    addGestureRecognizer(dismissPan)
    isAccessibilityElement = true
    accessibilityTraits = .image
    accessibilityLabel = "Image, \(Int(pixelSize.width)) by \(Int(pixelSize.height))"
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  /// Updates displayed content with progressive image resolution upgrades while maintaining spatial layout stability.
  func show(_ image: UIImage, isFull: Bool) {
    if hasFull && !isFull { return }
    hasFull = hasFull || isFull
    imageView.image = image
  }

  private var fitScale: CGFloat { ZoomMath.fitScale(image: pixelSize, bounds: bounds.size) }
  /// Evaluates whether the current zoom scale matches the aspect-fit baseline within floating-point epsilon.
  private var isAtMinimum: Bool { zoomScale <= minimumZoomScale + 0.0001 }

  /// Recalculates zoom boundaries, viewport scaling, and content centering across layout invalidations.
  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != lastBounds, bounds.width > 0 else { return }
    let wasAtMinimum = lastBounds == .zero || isAtMinimum
    lastBounds = bounds.size
    minimumZoomScale = fitScale
    maximumZoomScale = ZoomMath.maxScale(fit: fitScale, screenScale: window?.screen.scale ?? traitCollection.displayScale)
    if wasAtMinimum || zoomScale < minimumZoomScale { zoomScale = minimumZoomScale }
    center()
    if wasAtMinimum { contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top) }
  }

  /// Resets viewport magnification to the aspect-fit baseline without animation.
  func resetZoom() {
    guard minimumZoomScale > 0, !isAtMinimum else { return }
    setZoomScale(minimumZoomScale, animated: false)
  }

  /// Adjusts content insets dynamically to maintain centered positioning when the image is smaller than viewport bounds.
  private func center() {
    let inset = ZoomMath.centeringInsets(content: contentSize, bounds: bounds.size)
    contentInset = UIEdgeInsets(top: inset.vertical, left: inset.horizontal, bottom: inset.vertical, right: inset.horizontal)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

  @objc private func handleSingleTap() { onSingleTap() }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    if isAtMinimum {
      let point = gesture.location(in: imageView)
      zoom(to: ZoomMath.zoomRect(center: point, scale: fitScale * ZoomMath.doubleTapFactor, bounds: bounds.size), animated: true)
    } else {
      setZoomScale(minimumZoomScale, animated: true)
    }
  }

  /// Validates downward drag initiation only when viewport is unmagnified and trajectory is predominantly vertical.
  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard gesture === dismissPan else { return super.gestureRecognizerShouldBegin(gesture) }
    let v = dismissPan.velocity(in: self)
    return isAtMinimum && v.y > 0 && v.y > abs(v.x)
  }

  /// Drives interactive downward translation and backdrop opacity decay, triggering dismissal or spring restoration.
  @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
    let t = gesture.translation(in: self)
    switch gesture.state {
    case .changed:
      imageView.transform = CGAffineTransform(translationX: 0, y: max(0, t.y))
      alpha = 1 - min(0.5, max(0, t.y) / 600)
    case .ended where t.y > 120 || gesture.velocity(in: self).y > 900:
      onDismiss()
    default:
      UIView.animate(withDuration: 0.2) {
        self.imageView.transform = .identity
        self.alpha = 1
      }
    }
  }
}
