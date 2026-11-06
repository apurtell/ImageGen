import CoreGraphics

/// Geometric coordinate transformations mapping stored bitmap buffers to display orientation.
enum ExifOrientation {
  /// Computes display dimensions for stored bitmap extents under the specified EXIF orientation tag.
  static func displaySize(_ size: CGSize, orientation: Int) -> CGSize {
    (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
  }

  /// Calculates affine transformation mapping lower-left-origin bitmap coordinates to display orientation.
  static func transform(orientation: Int, size: CGSize) -> CGAffineTransform {
    let w = size.width
    let h = size.height
    return switch orientation {
    case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
    case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
    case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
    case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
    default: .identity
    }
  }
}
