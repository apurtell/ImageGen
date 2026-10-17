#if DEBUG
import Foundation

/// The pixel sizes the mock returns (plan §2.6): the 1K size per ratio, with 512 exactly half,
/// 2K twice and 4K four times. The documented 21:9-at-512 cell (792×168, 4.7:1) is an apparent
/// error; this rule gives 792×336.
///
/// Tests and screenshots depend on these values, for example 16:9 at 2K = 2752×1536. Each entry passes
/// the app's own output checks (aspect within 3%, megapixels within 1.5× of the size class), so only the
/// `lowRes` and `wrongAspect` scenarios make a reply show a "returned …" warning. Static data only.
enum MockImageSizes {
  /// The 1K size for each of the 14 ratios, as (width, height).
  static let oneK: [AspectRatio: (Int, Int)] = [
    .r1x1: (1024, 1024), .r3x4: (896, 1200), .r16x9: (1376, 768),
    .r2x3: (848, 1264), .r4x3: (1200, 896), .r9x16: (768, 1376),
    .r3x2: (1264, 848), .r4x5: (928, 1152), .r21x9: (1584, 672),
    .r1x4: (512, 2048), .r5x4: (1152, 928), .r1x8: (384, 3072),
    .r4x1: (2048, 512), .r8x1: (3072, 384),
  ]

  /// A missing aspect means 1:1 and a missing size means 1K. The mock uses these when the body has no
  /// `imageConfig`. The `!` cannot fail: the table has every `AspectRatio` case.
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
