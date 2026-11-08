#if DEBUG
import Foundation

/// Reference resolution lookup tables for mock image synthesis.
///
/// Defines baseline 1K dimensions across supported aspect ratios, scaling linearly by factors of
/// 0.5 (512px), 2.0 (2K), and 4.0 (4K). Dimensions satisfy pipeline validation constraints for aspect
/// tolerance (within 3%) and megapixel bounds, reserving fidelity warnings for synthetic fault-injection
/// scenarios.
enum MockImageSizes {
  /// Resolves concrete pixel dimensions for an optional aspect ratio and size class, defaulting to 1:1 and 1K.
  static func size(aspect: AspectRatio?, size: ImageSize?) -> (width: Int, height: Int) {
    let (w, h) = (aspect ?? .r1x1).oneKPixels
    switch size {
    case .s512: return (w / 2, h / 2)
    case .s1K, nil: return (w, h)
    case .s2K: return (w * 2, h * 2)
    case .s4K: return (w * 4, h * 4)
    }
  }
}
#endif
