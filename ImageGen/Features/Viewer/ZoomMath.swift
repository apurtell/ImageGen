import CoreGraphics

/// Geometry calculations governing image zoom transformations, aspect fit scaling, maximum magnification
/// boundaries, and content centering within scrollable presentation viewports.
enum ZoomMath {
  /// Calculates the aspect-fit scale factor required to display the entire image within the container bounds.
  static func fitScale(image: CGSize, bounds: CGSize) -> CGFloat {
    guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
    return min(bounds.width / image.width, bounds.height / image.height)
  }

  /// Determines the upper zoom ceiling, resolving the maximum between double 1:1 pixel rendering and a 4× fit factor.
  static func maxScale(fit: CGFloat, screenScale: CGFloat) -> CGFloat {
    max(2 / max(screenScale, 1), 4 * fit)
  }

  /// Magnification multiplier applied during double-tap gesture interactions relative to the fit scale.
  static let doubleTapFactor: CGFloat = 2.5

  /// Computes the target coordinate rectangle within the canvas coordinate space to zoom to a specific focal point.
  static func zoomRect(center point: CGPoint, scale: CGFloat, bounds: CGSize) -> CGRect {
    let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
    return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
  }

  /// Computes symmetric content insets to center image content when rendered dimensions are smaller than viewport bounds.
  static func centeringInsets(content: CGSize, bounds: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
    (max(0, (bounds.width - content.width) / 2), max(0, (bounds.height - content.height) / 2))
  }

  /// Computes toggle target scale alternating between fitted bounds and 1:1 pixel or double-tap magnification.
  static func toggleTarget(current: CGFloat, fit: CGFloat, actual: CGFloat, maxScale: CGFloat) -> CGFloat {
    guard current <= fit * 1.001 else { return fit }
    return min(actual > fit * 1.01 ? actual : fit * doubleTapFactor, maxScale)
  }

  /// Calculates stepped magnification offset bounded within valid scale intervals.
  static func stepped(_ current: CGFloat, zoomingIn: Bool, fit: CGFloat, maxScale: CGFloat) -> CGFloat {
    let next = zoomingIn ? current * 1.25 : current / 1.25
    return min(max(next, fit), maxScale)
  }
}
