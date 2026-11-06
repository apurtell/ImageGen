import ImageIO
import OSLog
import SwiftUI
import UIKit

/// Embeds a zooming UIScrollView inside a SwiftUI image viewer page.
///
/// Starts with a low-resolution thumbnail and upgrades to full resolution when the page becomes
/// current. Supports pinch zoom, double-tap zoom, single-tap to toggle toolbars, and downward
/// drag to dismiss.
struct ZoomableImageView: UIViewRepresentable {
  let image: ViewerImage
  let thumbnails: ThumbnailService
  /// True if this page is currently visible; controls full-resolution decoding and zoom reset.
  let isCurrent: Bool
  let onSingleTap: () -> Void
  let onDismiss: () -> Void

  /// Instantiates the scroll view and begins loading the thumbnail.
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

  /// Cancels in-flight decode tasks when the page is dismantled.
  static func dismantleUIView(_ view: ZoomingScrollView, coordinator: Coordinator) {
    coordinator.thumbnailTask?.cancel()
    coordinator.fullTask?.cancel()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Coordinates thumbnail and full-resolution decode tasks for the page.
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

    /// Starts full-resolution decoding when this page becomes current, or cancels if leaving.
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
        view?.show(decoded.uiImage, isFull: true)
      }
    }
  }
}

extension DecodedImage {
  /// Creates a UIImage from the decoded bitmap, applying its EXIF orientation.
  var uiImage: UIImage {
    let orientation: UIImage.Orientation =
      switch exifOrientation {
      case 2: .upMirrored
      case 3: .down
      case 4: .downMirrored
      case 5: .leftMirrored
      case 6: .right
      case 7: .rightMirrored
      case 8: .left
      default: .up
      }
    return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
  }
}

/// Scroll view that handles image zoom, centering, and gesture interactions.
///
/// Supports pinch-to-zoom, double-tap zoom toggling, single-tap to toggle controls,
/// and pulling down to dismiss.
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  let imageView = UIImageView()
  /// Pixel size of the image, adjusted for EXIF orientation.
  private let pixelSize: CGSize
  /// True once the full-resolution image has been displayed so thumbnails cannot overwrite it.
  private var hasFull = false
  /// Container dimensions from the previous layout pass to detect size changes.
  private var lastBounds = CGSize.zero
  private let dismissPan = UIPanGestureRecognizer()
  var onSingleTap: () -> Void = {}
  var onDismiss: () -> Void = {}

  init(pixelSize: CGSize) {
    // Avoid zero dimensions to ensure valid zoom scale calculations.
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
    // Prevent chrome toggle conflict when initiating double-tap zoom.
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

  /// Updates the displayed image, ignoring thumbnail updates once full resolution is shown.
  func show(_ image: UIImage, isFull: Bool) {
    if hasFull && !isFull { return }
    hasFull = hasFull || isFull
    imageView.image = image
  }

  private var fitScale: CGFloat { ZoomMath.fitScale(image: pixelSize, bounds: bounds.size) }
  /// Returns true if the current zoom scale is at minimum (fit scale).
  private var isAtMinimum: Bool { zoomScale <= minimumZoomScale + 0.0001 }

  /// Recalculates zoom limits and centers the image when bounds change.
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

  /// Resets the zoom back to aspect fit.
  func resetZoom() {
    guard minimumZoomScale > 0, !isAtMinimum else { return }
    setZoomScale(minimumZoomScale, animated: false)
  }

  /// Centers the image when it is smaller than the scroll view bounds.
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

  /// Starts the dismiss drag only when fully zoomed out and dragging downward.
  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard gesture === dismissPan else { return super.gestureRecognizerShouldBegin(gesture) }
    let v = dismissPan.velocity(in: self)
    return isAtMinimum && v.y > 0 && v.y > abs(v.x)
  }

  /// Translates the image downward and fades the background, dismissing if dragged past the threshold.
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
