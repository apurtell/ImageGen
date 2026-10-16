import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares uploads for the API (D§4.8 step 3): always re-encodes, so EXIF and GPS are stripped
/// and orientation is applied; never upscales; decodes with subsampling, never in full.
enum ImagePreprocessor {
  static let jpegQuality = 0.9

  /// Writes `destinationDir/<id>-<maxLongEdge>.<jpg|png>`.
  @concurrent
  static func prepare(source: URL, maxLongEdge: Int, destinationDir: URL, id: UUID) async throws -> PreparedImage {
    #if DEBUG
      let before = MemoryFootprint.current()
      defer {
        Log.imaging.debug(
          "prepare \(id.uuidString.prefix(4), privacy: .public): phys_footprint \(MemoryFootprint.mb(before), privacy: .public) → \(MemoryFootprint.mb(MemoryFootprint.current()), privacy: .public)"
        )
      }
    #endif
    guard let src = CGImageSourceCreateWithURL(source as CFURL, ImageInspector.noCache) else { throw UnsupportedImageError() }
    let info = try ImageInspector.inspect(src)
    let heif = isHEIF(info.utType)
    let keepPNG = !heif && info.hasAlpha && (info.utType == UTType.png.identifier || info.utType == UTType.webP.identifier)
    let image = try downscale(src, to: min(maxLongEdge, info.longEdge))
    let url = destinationDir.appendingPathComponent("\(id.uuidString)-\(maxLongEdge).\(keepPNG ? "png" : "jpg")")
    if keepPNG {
      try write(image, to: url, type: .png, quality: nil)
    } else {
      try write(info.hasAlpha ? flattened(image) : image, to: url, type: .jpeg, quality: jpegQuality)
    }
    return try described(url, mimeType: keepPNG ? "image/png" : "image/jpeg", longEdgeSetting: maxLongEdge)
  }

  /// Re-prepares at `factor ×` the current long edge (D§4.8 step 5), as JPEG at `quality` with any
  /// alpha flattened onto white (or keeping PNG when `flattenAlpha` is false and it was PNG).
  /// Writes next to the input, named for the new edge.
  @concurrent
  static func shrink(_ input: PreparedImage, factor: Double = 0.75, quality: Double = 0.85, flattenAlpha: Bool = true)
    async throws -> PreparedImage
  {
    guard let src = CGImageSourceCreateWithURL(input.url as CFURL, ImageInspector.noCache) else {
      throw UnsupportedImageError()
    }
    let info = try ImageInspector.inspect(src)
    let edge = max(1, Int((Double(info.longEdge) * factor).rounded(.down)))
    let image = try downscale(src, to: edge)
    let keepPNG = !flattenAlpha && input.mimeType == "image/png"
    let url = input.url.deletingLastPathComponent().appendingPathComponent(
      "\(stem(of: input.url))-\(edge).\(keepPNG ? "png" : "jpg")")
    if keepPNG {
      try write(image, to: url, type: .png, quality: nil)
    } else {
      try write(flattened(image), to: url, type: .jpeg, quality: quality)
    }
    return try described(url, mimeType: keepPNG ? "image/png" : "image/jpeg", longEdgeSetting: input.longEdgeSetting)
  }

  // MARK: Helpers

  static func isHEIF(_ type: String) -> Bool {
    guard let t = UTType(type) else { return false }
    return t.conforms(to: .heic) || t.conforms(to: .heif) || type == "public.heics"
  }

  /// A subsampled decode with the orientation applied; never larger than the source.
  static func downscale(_ source: CGImageSource, to maxPixelSize: Int) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw UnsupportedImageError()
    }
    return image
  }

  /// Draws the image onto white, dropping alpha.
  static func flattened(_ image: CGImage) throws -> CGImage {
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let ctx = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw UnsupportedImageError() }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    guard let out = ctx.makeImage() else { throw UnsupportedImageError() }
    return out
  }

  /// Writes with no metadata dictionary, so nothing from the source's EXIF, TIFF or GPS survives.
  static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double?) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
  }

  private static func described(_ url: URL, mimeType: String, longEdgeSetting: Int) throws -> PreparedImage {
    let info = try ImageInspector.inspect(url: url)
    let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    return PreparedImage(
      url: url, mimeType: mimeType, byteCount: bytes, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
      longEdgeSetting: longEdgeSetting)
  }

  /// `<id>-2048.jpg` → `<id>`; anything else keeps its name without the extension.
  private static func stem(of url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    if let dash = name.lastIndex(of: "-"), Int(name[name.index(after: dash)...]) != nil {
      return String(name[..<dash])
    }
    return name
  }
}
