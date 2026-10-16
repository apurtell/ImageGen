import CoreGraphics

/// The viewer's zoom rules (D§3.7). The image view is sized in image pixels as points, so a zoom
/// scale of 1 shows one image pixel per point.
enum ZoomMath {
  /// The scale that fits the whole image in the bounds.
  static func fitScale(image: CGSize, bounds: CGSize) -> CGFloat {
    guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
    return min(bounds.width / image.width, bounds.height / image.height)
  }

  /// The larger of 1:1 pixels × 2 and 4× the fit scale.
  static func maxScale(fit: CGFloat, screenScale: CGFloat) -> CGFloat {
    max(2 / max(screenScale, 1), 4 * fit)
  }

  /// Double-tap zooms to 2.5× the fit scale.
  static let doubleTapFactor: CGFloat = 2.5

  /// The rect, in image-view coordinates, to zoom to so that `point` is centered at `scale`.
  static func zoomRect(center point: CGPoint, scale: CGFloat, bounds: CGSize) -> CGRect {
    let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
    return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
  }

  /// Insets that center content smaller than the bounds.
  static func centeringInsets(content: CGSize, bounds: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
    (max(0, (bounds.width - content.width) / 2), max(0, (bounds.height - content.height) / 2))
  }
}
