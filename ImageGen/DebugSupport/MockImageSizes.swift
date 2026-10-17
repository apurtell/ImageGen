#if DEBUG
import Foundation

/// Reference resolution lookup tables for mock image synthesis.
///
/// Defines baseline 1K dimensions across supported aspect ratios, scaling linearly by factors of
/// 0.5 (512px), 2.0 (2K), and 4.0 (4K). Dimensions satisfy pipeline validation constraints for aspect
/// tolerance (within 3%) and megapixel bounds, reserving fidelity warnings for synthetic fault-injection
/// scenarios.
enum MockImageSizes {
  /// Baseline 1K pixel dimensions for all supported aspect ratios, represented as (width, height) tuples.
  static let oneK: [AspectRatio: (Int, Int)] = [
    .r1x1: (1024, 1024), .r3x4: (896, 1200), .r16x9: (1376, 768),
    .r2x3: (848, 1264), .r4x3: (1200, 896), .r9x16: (768, 1376),
    .r3x2: (1264, 848), .r4x5: (928, 1152), .r21x9: (1584, 672),
    .r1x4: (512, 2048), .r5x4: (1152, 928), .r1x8: (384, 3072),
    .r4x1: (2048, 512), .r8x1: (3072, 384),
  ]

  /// Resolves concrete pixel dimensions for an optional aspect ratio and size class, defaulting to 1:1 and 1K.
  static func size(aspect: AspectRatio?, size: ImageSize?) -> (width: Int, height: Int) {
    let (w, h) = oneK[aspect ?? .r1x1]!
    switch size {
    case .s512: return (w / 2, h / 2)
    case .s1K, nil: return (w, h)
    case .s2K: return (w * 2, h * 2)
    case .s4K: return (w * 4, h * 4)
    }
  }
}
#endif
