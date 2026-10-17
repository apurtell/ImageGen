#if DEBUG
import UIKit

/// Draws the mock's images: a gradient whose hue comes from the prompt, with the prompt and the
/// settings written on it.
///
/// Users: `MockGeminiURLProtocol` (the mock's responses), `DemoSeeder` (seeded images and uploads) and
/// `DebugHooks` (the pasteboard image). The same prompt always gives the same hue, so screenshots are
/// stable across runs. It uses UIKit drawing, which is safe off the main thread; the mock calls it on
/// the URL loading thread. No state.
enum MockImageRenderer {
  /// JPEG bytes at exactly `width` × `height` pixels. The scale is 1, so points equal pixels and the
  /// image size matches the `MockImageSizes` table.
  static func jpeg(width: Int, height: Int, prompt: String, caption: String) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let size = CGSize(width: width, height: height)
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    // A djb2-style string hash. `&*` and `&+` are Swift's wrapping operators: they ignore overflow
    // instead of stopping the app, which plain `*` and `+` would do.
    let hue = CGFloat(abs(prompt.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
    let image = renderer.image { ctx in
      let colors = [
        UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor,
        UIColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.45, alpha: 1).cgColor,
      ] as CFArray
      let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
      ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
      // The text scales with the short side, so it stays readable on 512 px and on 4K images.
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
