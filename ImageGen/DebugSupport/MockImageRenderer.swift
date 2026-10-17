#if DEBUG
import UIKit

/// Generates deterministic synthetic test images featuring prompt-derived background gradients
/// overlaid with descriptive diagnostic metadata and settings captions.
///
/// Shared across debug subsystems including `MockGeminiURLProtocol`, `DemoSeeder`, and `DebugHooks`.
/// Deterministic prompt hashing ensures visual consistency across automated UI runs and snapshots.
/// Render operations rely on thread-safe `UIGraphicsImageRenderer` primitives, enabling direct
/// invocation from background URL loading threads.
enum MockImageRenderer {
  /// Renders and compresses a synthetic image to JPEG format matching the specified pixel dimensions.
  /// A display scale of 1.0 ensures a 1:1 mapping between coordinate points and output pixels.
  static func jpeg(width: Int, height: Int, prompt: String, caption: String) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let size = CGSize(width: width, height: height)
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    // Derives a deterministic gradient hue using a djb2-style string hash with wrapping arithmetic.
    let hue = CGFloat(abs(prompt.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
    let image = renderer.image { ctx in
      let colors = [
        UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor,
        UIColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.45, alpha: 1).cgColor,
      ] as CFArray
      let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
      ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
      // Proportional font sizing maintains legibility across diverse dimension scales.
      let fontSize = max(14, min(size.width, size.height) / 14)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: UIColor.white,
      ]
      let text = "\(prompt)\n\(caption)" as NSString
      text.draw(
        in: CGRect(x: fontSize, y: fontSize, width: size.width - 2 * fontSize, height: size.height - 2 * fontSize),
        withAttributes: attributes)
    }
    return image.jpegData(compressionQuality: 0.8) ?? Data()
  }
}
#endif
