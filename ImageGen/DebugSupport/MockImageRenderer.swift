#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates deterministic synthetic test images: a prompt-derived gradient with the prompt and a
/// settings caption drawn over it.
///
/// Shared by `MockGeminiURLProtocol`, `DemoSeeder` and `DebugHooks`. The prompt hash makes the
/// output repeatable across UI runs. Built with CoreGraphics, CoreText and ImageIO only, so it is
/// platform-independent and safe to call from background URL loading threads.
enum MockImageRenderer {
  /// Renders a synthetic test image and encodes it as JPEG at the requested pixel dimensions.
  static func jpeg(width: Int, height: Int, prompt: String, caption: String) -> Data {
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return Data() }
    let size = CGSize(width: width, height: height)
    // Hashes the prompt to pick a stable hue so identical prompts produce the same gradient.
    let hue = CGFloat(abs(prompt.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
    let colors =
      [
        color(hue: hue, saturation: 0.6, brightness: 0.9),
        color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.45),
      ] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else {
      return Data()
    }
    // CoreGraphics coordinates start at bottom-left: the gradient runs from top-left to bottom-right.
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    // Scale font size proportionally to keep the text readable across dimensions.
    let fontSize = max(14, min(size.width, size.height) / 14)
    let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
      ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ]
    let text = NSAttributedString(string: "\(prompt)\n\(caption)", attributes: attributes)
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let path = CGPath(
      rect: CGRect(x: fontSize, y: fontSize, width: size.width - 2 * fontSize, height: size.height - 2 * fontSize),
      transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)

    guard let image = ctx.makeImage() else { return Data() }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      return Data()
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? out as Data : Data()
  }

  /// Converts HSB color components to an sRGB `CGColor`.
  private static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
    let h = hue * 6
    let c = brightness * saturation
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = brightness - c
    let (r, g, b): (CGFloat, CGFloat, CGFloat) =
      switch Int(h) % 6 {
      case 0: (c, x, 0)
      case 1: (x, c, 0)
      case 2: (0, c, x)
      case 3: (0, x, c)
      case 4: (x, 0, c)
      default: (c, 0, x)
      }
    return CGColor(red: r + m, green: g + m, blue: b + m, alpha: 1)
  }
}
#endif
