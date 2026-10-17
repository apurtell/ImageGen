import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image transformation pipeline sanitizing and downsampling user attachments for API submission.
///
/// Processing Pipeline:
/// - Strips sensitive metadata containers (EXIF, TIFF, GPS) by re-encoding all outbound assets.
/// - Normalizes coordinate orientation based on container tags without allocating uncompressed full-resolution bitmaps.
/// - Utilizes ImageIO hardware-accelerated thumbnail generation to perform subsampled decoding directly
///   into targeted dimensional bounds.
/// - Concurrency guarantees: All pipeline operations are stateless and execute concurrently off the calling actor
///   context via `@concurrent`. File persistence leverages atomic POSIX file replacement to eliminate partial writes.
enum ImagePreprocessor {
  static let jpegQuality = 0.9

  /// Prepares an input image artifact constrained to the designated long-edge resolution tier.
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
    try Task.checkCancellation()
    let image = try downscale(src, to: min(maxLongEdge, info.longEdge))
    try Task.checkCancellation()
    let url = destinationDir.appendingPathComponent("\(id.uuidString)-\(maxLongEdge).\(keepPNG ? "png" : "jpg")")
    if keepPNG {
      try write(image, to: url, type: .png, quality: nil)
    } else {
      try write(info.hasAlpha ? flattened(image) : image, to: url, type: .jpeg, quality: jpegQuality)
    }
    return try described(url, mimeType: keepPNG ? "image/png" : "image/jpeg", longEdgeSetting: maxLongEdge)
  }

  /// Iteratively scales an existing prepared artifact to satisfy request payload budget constraints.
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
      "\(stem(of: input.url))-s\(edge).\(keepPNG ? "png" : "jpg")")
    if keepPNG {
      try write(image, to: url, type: .png, quality: nil)
    } else {
      try write(flattened(image), to: url, type: .jpeg, quality: quality)
    }
    return try described(url, mimeType: keepPNG ? "image/png" : "image/jpeg", longEdgeSetting: input.longEdgeSetting)
  }

  static func isHEIF(_ type: String) -> Bool {
    guard let t = UTType(type) else { return false }
    return t.conforms(to: .heic) || t.conforms(to: .heif) || type == "public.heics"
  }

  /// Decodes and subsamples image content directly to the target pixel bounding box with transforms applied.
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

  /// Composites transparent alpha channels against an opaque solid white background.
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

  /// Serializes bitmap to disk atomically via temporary staging files, omitting source metadata dictionaries.
  static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double?) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
    guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest), rename(temp.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temp)
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
  }

  /// Verifies on-disk file dimensions and byte length following encoding.
  private static func described(_ url: URL, mimeType: String, longEdgeSetting: Int) throws -> PreparedImage {
    let info = try ImageInspector.inspect(url: url)
    let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    return PreparedImage(
      url: url, mimeType: mimeType, byteCount: bytes, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
      longEdgeSetting: longEdgeSetting)
  }

  /// Extracts the base identifier stem from prepared and scaled image file names.
  static func stem(of url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    guard let dash = name.lastIndex(of: "-") else { return name }
    var suffix = name[name.index(after: dash)...]
    if suffix.first == "s" { suffix = suffix.dropFirst() }
    return !suffix.isEmpty && Int(suffix) != nil ? String(name[..<dash]) : name
  }
}
