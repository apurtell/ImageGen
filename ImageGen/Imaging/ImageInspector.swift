import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata extracted from image container headers without pixel rasterization.
struct ImageInfo: Sendable, Equatable {
  let utType: String
  let mimeType: String
  /// Native pixel dimensions prior to applying orientation transformations.
  let pixelWidth: Int
  let pixelHeight: Int
  /// Standard EXIF orientation indicator (values 1 through 8).
  let orientation: Int
  let hasAlpha: Bool
  let frameCount: Int

  /// Effective display dimensions accounting for 90-degree rotational coordinate transpositions.
  var orientedWidth: Int { orientation >= 5 ? pixelHeight : pixelWidth }
  var orientedHeight: Int { orientation >= 5 ? pixelWidth : pixelHeight }
  var longEdge: Int { max(pixelWidth, pixelHeight) }
}

/// Domain error indicating unreadable, corrupted, or unsupported image container data.
struct UnsupportedImageError: LocalizedError, Equatable {
  var errorDescription: String? { "Unsupported or damaged image" }
}

/// Metadata inspection utility leveraging ImageIO property queries to avoid full bitmap decompression.
enum ImageInspector {
  /// Property configuration instructing ImageIO to disable pixel buffer caching.
  static var noCache: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

  static func inspect(url: URL) throws -> ImageInfo {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache) else { throw UnsupportedImageError() }
    return try inspect(source)
  }

  static func inspect(data: Data) throws -> ImageInfo {
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else { throw UnsupportedImageError() }
    return try inspect(source)
  }

  /// Extracts container metadata and primary frame attributes from an existing `CGImageSource`.
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
