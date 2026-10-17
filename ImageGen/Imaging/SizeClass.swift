import Foundation

/// Whether the API honored the requested size and aspect ratio (D§3.4, R3 and R4). Pure.
/// The reply's metadata line uses it to show a "returned …" warning when the output differs from the
/// request. It has no state, so any thread can call it.
enum SizeClass {
  static let sizeTolerance = 1.5
  static let aspectTolerance = 0.03

  static func megapixels(width: Int, height: Int) -> Double {
    Double(width) * Double(height) / 1_000_000
  }

  /// The size class with the nearest nominal megapixels (by ratio). Pixel count, not the long edge,
  /// because extreme ratios have long edges outside the usual range (1:8 at 1K is 384×3072).
  static func classify(width: Int, height: Int) -> ImageSize {
    // Compare by the log of the ratio, so "twice as large" and "half as large" count as the same distance.
    let mp = megapixels(width: width, height: height)
    return ImageSize.allCases.min { abs(log(mp / $0.nominalMegapixels)) < abs(log(mp / $1.nominalMegapixels)) }!
  }

  /// Within a factor of 1.5 of the requested class's nominal megapixels.
  static func isSizeHonored(requested: ImageSize, width: Int, height: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    let ratio = megapixels(width: width, height: height) / requested.nominalMegapixels
    return ratio <= sizeTolerance && ratio >= 1 / sizeTolerance
  }

  /// Within 3% of the requested ratio.
  static func isAspectHonored(requested: AspectRatio, width: Int, height: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    return abs((Double(width) / Double(height)) / requested.ratio - 1) <= aspectTolerance
  }

  /// The nearest of the 14 ratios, for a "returned 1:1" marker.
  static func nearestAspect(width: Int, height: Int) -> AspectRatio {
    let actual = Double(width) / Double(max(1, height))
    return AspectRatio.allCases.min { abs(log(actual / $0.ratio)) < abs(log(actual / $1.ratio)) }!
  }
}
