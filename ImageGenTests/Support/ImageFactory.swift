import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// In-memory image generator synthesizing deterministic CoreGraphics and ImageIO fixtures for automated tests.
enum ImageFactory {
  static func cgImage(width: Int, height: Int, alpha: Bool = false, seed: Int = 0) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: info.rawValue)!
    let hue = CGFloat(seed % 7) / 7
    let colors = [
      CGColor(srgbRed: hue, green: 0.3, blue: 0.7, alpha: alpha ? 0.5 : 1),
      CGColor(srgbRed: 0.9, green: 1 - hue, blue: 0.2, alpha: 1),
    ] as CFArray
    let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return ctx.makeImage()!
  }

  static func jpeg(
    width: Int = 64, height: Int = 48, orientation: Int = 1, gps: Bool = false, quality: Double = 0.8,
    seed: Int = 0
  ) -> Data {
    var props: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality,
      kCGImagePropertyOrientation: orientation,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: orientation],
    ]
    if gps {
      props[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W",
      ]
    }
    return encode(cgImage(width: width, height: height, seed: seed), type: .jpeg, properties: props)
  }

  static func png(width: Int = 32, height: Int = 18, alpha: Bool = false, seed: Int = 0) -> Data {
    encode(cgImage(width: width, height: height, alpha: alpha, seed: seed), type: .png)
  }

  static func heic(width: Int = 64, height: Int = 48, alpha: Bool = false, seed: Int = 0) -> Data {
    encode(
      cgImage(width: width, height: height, alpha: alpha, seed: seed), type: .heic,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.7])
  }

  static func gif(width: Int = 32, height: Int = 32, seed: Int = 0) -> Data {
    encode(cgImage(width: width, height: height, seed: seed), type: .gif)
  }

  static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "cannot encode \(type.identifier)")
    return data as Data
  }

  /// Inspects encoded image data to extract pixel dimensions and EXIF orientation metadata via ImageIO.
  static func inspect(_ data: Data) -> (width: Int, height: Int, orientation: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h, props[kCGImagePropertyOrientation] as? Int ?? 1)
  }
}
