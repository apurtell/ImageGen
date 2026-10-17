import ImageIO
import OSLog
import SwiftUI
import UIKit

/// One page of the viewer (D§3.7): a `UIScrollView` that fits the image, zooms to the larger of
/// 1:1 × 2 and 4× fit, double-taps between fit and 2.5× at the tap point, and keeps the image
/// centered while zoomed out. The 1200 px thumbnail shows until the full decode, made off the main
/// actor, replaces it. A downward swipe at the minimum zoom dismisses.
///
/// The file has three parts: this `UIViewRepresentable` bridge, the `FullDecode` helper, and the
/// UIKit `ZoomingScrollView`. A UIKit scroll view is used because it gives real pinch zoom, zoom to a
/// rectangle, and bounce; SwiftUI has no built-in view that does all of this. `ImageViewer` makes one per page.
///
/// Concurrency: the views and the coordinator run on the main actor. Each page has one load task.
/// It awaits the thumbnail from the `ThumbnailService` actor, then runs the full decode in a
/// detached task on a background thread. When SwiftUI removes the page (for example when the pager
/// is rebuilt or the viewer closes), `dismantleUIView` cancels the load task, so a late decode result is
/// not shown. Cancellation does not stop a decode that has already started; it finishes, and its
/// result is dropped.
struct ZoomableImageView: UIViewRepresentable {
  let image: ViewerImage
  let thumbnails: ThumbnailService
  /// False for the pages next to the one on screen; they reset to the fitted zoom.
  let isCurrent: Bool
  let onSingleTap: () -> Void
  let onDismiss: () -> Void

  /// Called once per page. The load starts here, so it runs once for the life of the UIKit view.
  func makeUIView(context: Context) -> ZoomingScrollView {
    let view = ZoomingScrollView(pixelSize: CGSize(width: image.item.pixelWidth, height: image.item.pixelHeight))
    view.onSingleTap = onSingleTap
    view.onDismiss = onDismiss
    context.coordinator.load(image, into: view, thumbnails: thumbnails)
    return view
  }

  func updateUIView(_ view: ZoomingScrollView, context: Context) {
    // The closures are copied again on each update, so the UIKit view calls the latest ones.
    view.onSingleTap = onSingleTap
    view.onDismiss = onDismiss
    if !isCurrent { view.resetZoom() }
  }

  /// SwiftUI calls this when it removes the UIKit view. It is the one place that stops the load.
  static func dismantleUIView(_ view: ZoomingScrollView, coordinator: Coordinator) {
    coordinator.task?.cancel()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Holds the load task, so that `dismantleUIView` can cancel it.
  @MainActor
  final class Coordinator {
    var task: Task<Void, Never>?

    func load(_ image: ViewerImage, into view: ZoomingScrollView, thumbnails: ThumbnailService) {
      // Plain `Sendable` values, copied before the tasks, so the detached task needs nothing from
      // the main actor.
      let url = image.item.url
      let id = image.item.id
      // `Task {}` inherits the main actor, so the `view?.show` calls run on the main thread.
      // `[weak view]`: the task does not keep a removed page's view alive; `view?` is then nil.
      task = Task { [weak view] in
        if let thumb = await thumbnails.thumbnail(for: url, id: id, px: ThumbnailService.bubbleSize) {
          view?.show(UIImage(cgImage: thumb), isFull: false)
        }
        // Checked before the costly decode, so a page removed during the thumbnail load decodes nothing.
        guard !Task.isCancelled else { return }
        // `Task.detached` has no actor, so the decode runs off the main thread. It is a separate
        // task: cancelling this one does not cancel it.
        let full = await Task.detached(priority: .userInitiated) { FullDecode.decode(url: url, id: id) }.value
        // Checked again after the `await`: the page may be gone, and its result must not be shown.
        guard !Task.isCancelled, let full else { return }
        view?.show(full, isFull: true)
      }
    }
  }
}

/// The full-resolution decode (D§3.7), off the main actor, with the stored orientation applied.
/// Synchronous and slow (a 4K image is about 67 MB decoded); callers run it in a detached task.
enum FullDecode {
  /// nil when the file cannot be read or decoded; the page then keeps the thumbnail.
  static func decode(url: URL, id: UUID) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, ImageInspector.noCache),
      let info = try? ImageInspector.inspect(source)  // try?: an unreadable file keeps the thumbnail on screen.
    else { return nil }
    // Decode now, on this background thread, not lazily on the main thread at first draw.
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

  /// Maps the EXIF orientation value (1 to 8) to UIKit's orientation. Unknown values count as up.
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

/// The UIKit scroll view for one page. The image view is sized in image pixels, as points, and the
/// scroll view zooms it (see `ZoomMath`). It is its own delegate, and it adds three gestures:
/// double tap (zoom), single tap (chrome) and a downward pan (dismiss). Main thread only.
final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  let imageView = UIImageView()
  /// As displayed (orientation applied), in pixels.
  private let pixelSize: CGSize
  /// Set once the full image is shown. After that, a thumbnail never replaces it.
  private var hasFull = false
  /// The bounds at the last layout, so the zoom is set again only when the size changes.
  private var lastBounds = CGSize.zero
  private let dismissPan = UIPanGestureRecognizer()
  var onSingleTap: () -> Void = {}
  var onDismiss: () -> Void = {}

  init(pixelSize: CGSize) {
    // At least 1 × 1, so the zoom math never divides by zero.
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
    // A single tap waits until the double tap fails, so a double tap does not also toggle the chrome.
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

  /// Shows the thumbnail or the full image. The thumbnail is smaller, but the image view keeps its
  /// pixel-sized frame, so the swap does not change the zoom.
  func show(_ image: UIImage, isFull: Bool) {
    if hasFull && !isFull { return }
    hasFull = hasFull || isFull
    imageView.image = image
  }

  private var fitScale: CGFloat { ZoomMath.fitScale(image: pixelSize, bounds: bounds.size) }
  /// A small tolerance, because a floating-point zoom scale is not always exactly the minimum.
  private var isAtMinimum: Bool { zoomScale <= minimumZoomScale + 0.0001 }

  /// Sets the zoom limits for the current size: on the first layout, and after each rotation.
  override func layoutSubviews() {
    super.layoutSubviews()
    // Layout runs often (for example during every scroll); only a size change needs new limits.
    guard bounds.size != lastBounds, bounds.width > 0 else { return }
    // A fitted image stays fitted at the new size. A zoomed image keeps its zoom when it can.
    let wasAtMinimum = lastBounds == .zero || isAtMinimum
    lastBounds = bounds.size
    minimumZoomScale = fitScale
    maximumZoomScale = ZoomMath.maxScale(fit: fitScale, screenScale: window?.screen.scale ?? traitCollection.displayScale)
    if wasAtMinimum || zoomScale < minimumZoomScale { zoomScale = minimumZoomScale }
    center()
    // After a rotation the old offset would leave the fitted image off-center.
    if wasAtMinimum { contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top) }
  }

  /// Back to the fitted zoom without animation, for a page that is no longer on screen.
  func resetZoom() {
    guard minimumZoomScale > 0, !isAtMinimum else { return }
    setZoomScale(minimumZoomScale, animated: false)
  }

  /// Centers an image smaller than the view with content insets. The insets change with each zoom.
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

  // MARK: Swipe down to dismiss (at the minimum zoom only)

  /// The dismiss pan begins only at the minimum zoom and for a mostly downward motion. Otherwise the
  /// scroll view's own pan (and the pager's horizontal swipe) handle the touch.
  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard gesture === dismissPan else { return super.gestureRecognizerShouldBegin(gesture) }
    let v = dismissPan.velocity(in: self)
    return isAtMinimum && v.y > 0 && v.y > abs(v.x)
  }

  /// The image follows the finger down and the page fades. A long or fast swipe dismisses;
  /// anything else springs back.
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
