import Foundation

/// Diagnostics verifying generated image geometry against requested aspect ratios and size tiers.
/// Provides functional evaluation routines to determine whether model outputs satisfy configuration boundaries.
enum SizeClass {
  static let sizeTolerance = 1.5
  static let aspectTolerance = 0.03

  static func megapixels(width: Int, height: Int) -> Double {
    Double(width) * Double(height) / 1_000_000
  }

  /// Classifies pixel dimensions to the nearest canonical `ImageSize` tier by logarithmic area distance.
  static func classify(width: Int, height: Int) -> ImageSize {
    let mp = megapixels(width: width, height: height)
    return ImageSize.allCases.min { abs(log(mp / $0.nominalMegapixels)) < abs(log(mp / $1.nominalMegapixels)) }!
  }

  /// Validates whether generated pixel count falls within allowable proportional tolerance of the requested size tier.
  static func isSizeHonored(requested: ImageSize, width: Int, height: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    let ratio = megapixels(width: width, height: height) / requested.nominalMegapixels
    return ratio <= sizeTolerance && ratio >= 1 / sizeTolerance
  }

  /// Validates whether the dimensional aspect ratio falls within acceptable tolerance of the requested ratio.
  static func isAspectHonored(requested: AspectRatio, width: Int, height: Int) -> Bool {
    guard width > 0, height > 0 else { return false }
    return abs((Double(width) / Double(height)) / requested.ratio - 1) <= aspectTolerance
  }

  /// Resolves the nearest canonical `AspectRatio` matching actual pixel dimensions.
  static func nearestAspect(width: Int, height: Int) -> AspectRatio {
    let actual = Double(width) / Double(max(1, height))
    return AspectRatio.allCases.min { abs(log(actual / $0.ratio)) < abs(log(actual / $1.ratio)) }!
  }
}
