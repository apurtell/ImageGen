import CoreGraphics

/// Layout metrics and window rect calculation algorithms for desktop image viewing windows.
enum ViewerWindowSizing {
  /// Absolute minimum content dimensions permitted during manual window resizing.
  static let minimumContent = CGSize(width: 360, height: 280)
  /// Minimum initial presentation content dimensions ensuring toolbar chrome visibility.
  static let minContent = CGSize(width: 480, height: 360)
  /// Fallback content dimensions applied when asset pixel measurements are unavailable.
  static let fallback = CGSize(width: 900, height: 650)

  /// Constrains target window frame within screen bounds, repositioning and clamping dimensions as required.
  static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
    var result = frame
    result.size.width = min(result.width, visible.width)
    if result.height > visible.height {
      result.origin.y += result.height - visible.height
      result.size.height = visible.height
    }
    if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
    if result.minX < visible.minX { result.origin.x = visible.minX }
    if result.minY < visible.minY { result.origin.y = visible.minY }
    if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
    return result
  }

  /// Computes frame centered within target container bounds.
  static func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
    CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
  }

  /// Computes initial presentation dimensions scaling asset pixel extents to device display boundaries.
  static func contentSize(image: CGSize, available: CGSize, pixelScale: CGFloat, fraction: CGFloat = 0.9) -> CGSize {
    let limit = CGSize(width: max(1, available.width * fraction), height: max(1, available.height * fraction))
    guard image.width > 0, image.height > 0 else {
      return CGSize(width: min(fallback.width, limit.width), height: min(fallback.height, limit.height))
    }
    let natural = CGSize(width: image.width / max(pixelScale, 1), height: image.height / max(pixelScale, 1))
    let scale = min(1, limit.width / natural.width, limit.height / natural.height)
    return CGSize(
      width: min(max((natural.width * scale).rounded(), minContent.width), limit.width),
      height: min(max((natural.height * scale).rounded(), minContent.height), limit.height))
  }
}
