import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an image is, read from its properties without decoding it (D§4.8 step 2).
struct ImageInfo: Sendable, Equatable {
  let utType: String
  let mimeType: String
  /// As stored, before orientation is applied.
  let pixelWidth: Int
  let pixelHeight: Int
  /// EXIF orientation, 1–8.
  let orientation: Int
  let hasAlpha: Bool
  let frameCount: Int

  /// Orientations 5–8 rotate by 90°, so they swap width and height for display.
  var orientedWidth: Int { orientation >= 5 ? pixelHeight : pixelWidth }
  var orientedHeight: Int { orientation >= 5 ? pixelWidth : pixelHeight }
  var longEdge: Int { max(pixelWidth, pixelHeight) }
}

struct UnsupportedImageError: LocalizedError, Equatable {
  var errorDescription: String? { "Unsupported or damaged image" }
}

enum ImageInspector {
  static var noCache: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

  static func inspect(url: URL) throws -> ImageInfo {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache) else { throw UnsupportedImageError() }
    return try inspect(source)
  }

  static func inspect(data: Data) throws -> ImageInfo {
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else { throw UnsupportedImageError() }
    return try inspect(source)
  }

  static func inspect(_ source: CGImageSource) throws -> ImageInfo {
    guard CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw UnsupportedImageError() }
    return ImageInfo(
      utType: type, mimeType: UTType(type)?.preferredMIMEType ?? "application/octet-stream",
      pixelWidth: width, pixelHeight: height,
      orientation: (props[kCGImagePropertyOrientation] as? Int).flatMap { (1...8).contains($0) ? $0 : nil } ?? 1,
      hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
      frameCount: CGImageSourceGetCount(source))
  }
}
