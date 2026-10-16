import ImageIO
import OSLog
import SwiftUI
import UIKit

/// One page of the viewer (D§3.7): a `UIScrollView` that fits the image, zooms to the larger of
/// 1:1 × 2 and 4× fit, double-taps between fit and 2.5× at the tap point, and keeps the image
/// centered while zoomed out. The 1200 px thumbnail shows until the full decode, made off the main
/// actor, replaces it. A downward swipe at the minimum zoom dismisses.
struct ZoomableImageView: UIViewRepresentable {
  let image: ViewerImage
  let thumbnails: ThumbnailService
  let isCurrent: Bool
  let onSingleTap: () -> Void
  let onDismiss: () -> Void

  func makeUIView(context: Context) -> ZoomingScrollView {
    let view = ZoomingScrollView(pixelSize: CGSize(width: image.item.pixelWidth, height: image.item.pixelHeight))
    view.onSingleTap = onSingleTap
    view.onDismiss = onDismiss
    context.coordinator.load(image, into: view, thumbnails: thumbnails)
    return view
  }

  func updateUIView(_ view: ZoomingScrollView, context: Context) {
    view.onSingleTap = onSingleTap
    view.onDismiss = onDismiss
    if !isCurrent { view.resetZoom() }
  }

  static func dismantleUIView(_ view: ZoomingScrollView, coordinator: Coordinator) {
    coordinator.task?.cancel()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor
  final class Coordinator {
    var task: Task<Void, Never>?

    func load(_ image: ViewerImage, into view: ZoomingScrollView, thumbnails: ThumbnailService) {
      let url = image.item.url
      let id = image.item.id
      task = Task { [weak view] in
        if let thumb = await thumbnails.thumbnail(for: url, id: id, px: ThumbnailService.bubbleSize) {
          view?.show(UIImage(cgImage: thumb), isFull: false)
        }
        guard !Task.isCancelled else { return }
        let full = await Task.detached(priority: .userInitiated) { FullDecode.decode(url: url, id: id) }.value
        guard !Task.isCancelled, let full else { return }
        view?.show(full, isFull: true)
      }
    }
  }
}

/// The full-resolution decode (D§3.7), off the main actor, with the stored orientation applied.
enum FullDecode {
  static func decode(url: URL, id: UUID) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, ImageInspector.noCache),
      let info = try? ImageInspector.inspect(source)
    else { return nil }
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

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  let imageView = UIImageView()
  /// As displayed (orientation applied), in pixels.
  private let pixelSize: CGSize
  private var hasFull = false
  private var lastBounds = CGSize.zero
  private let dismissPan = UIPanGestureRecognizer()
  var onSingleTap: () -> Void = {}
  var onDismiss: () -> Void = {}

  init(pixelSize: CGSize) {
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

  func show(_ image: UIImage, isFull: Bool) {
    if hasFull && !isFull { return }
    hasFull = hasFull || isFull
    imageView.image = image
  }

  private var fitScale: CGFloat { ZoomMath.fitScale(image: pixelSize, bounds: bounds.size) }
  private var isAtMinimum: Bool { zoomScale <= minimumZoomScale + 0.0001 }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != lastBounds, bounds.width > 0 else { return }
    let wasAtMinimum = lastBounds == .zero || isAtMinimum
    lastBounds = bounds.size
    minimumZoomScale = fitScale
    maximumZoomScale = ZoomMath.maxScale(fit: fitScale, screenScale: window?.screen.scale ?? traitCollection.displayScale)
    if wasAtMinimum || zoomScale < minimumZoomScale { zoomScale = minimumZoomScale }
    center()
    // After a rotation the old offset would leave the fitted image off-center.
    if wasAtMinimum { contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top) }
  }

  func resetZoom() {
    guard minimumZoomScale > 0, !isAtMinimum else { return }
    setZoomScale(minimumZoomScale, animated: false)
  }

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

  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard gesture === dismissPan else { return super.gestureRecognizerShouldBegin(gesture) }
    let v = dismissPan.velocity(in: self)
    return isAtMinimum && v.y > 0 && v.y > abs(v.x)
  }

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
