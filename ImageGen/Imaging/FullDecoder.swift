import CoreGraphics
import Foundation
import ImageIO

/// A decoded bitmap and its EXIF orientation, ready for display.
final class DecodedImage: Sendable {
  let cgImage: CGImage
  let exifOrientation: Int

  init(cgImage: CGImage, exifOrientation: Int) {
    self.cgImage = cgImage
    self.exifOrientation = exifOrientation
  }
}

/// Decodes full-resolution images off the main thread and caches the most recent image
/// so interface rotations and layout passes do not reload from disk.
actor FullDecoder {
  static let shared = FullDecoder()
  private var last: (id: UUID, image: DecodedImage)?

  /// Decodes the image from disk, returning the cached image if already decoded.
  func decode(url: URL, id: UUID) -> DecodedImage? {
    if let last, last.id == id { return last.image }
    guard !Task.isCancelled else { return nil }
    let image = FullDecode.decode(url: url, id: id)
    last = image.map { (id, $0) }
    return image
  }

  /// Releases the cached image when the viewer is dismissed.
  func clear() { last = nil }
}

/// Synchronous image decoding helpers.
enum FullDecode {
  /// Decodes the full-resolution image from disk and extracts its orientation.
  static func decode(url: URL, id: UUID) -> DecodedImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, ImageInspector.noCache),
      let info = try? ImageInspector.inspect(source)
    else { return nil }
    // Decode pixel data immediately on the background thread to avoid UI hitching when first displayed.
    let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    guard let cg = DecodeTimer().measure("viewer full \(info.pixelWidth)×\(info.pixelHeight)", { CGImageSourceCreateImageAtIndex(source, 0, options) })
    else { return nil }
    #if DEBUG
      Log.imaging.debug(
        "viewer decode img \(Format.short(id), privacy: .public) \(info.pixelWidth)×\(info.pixelHeight): phys_footprint \(MemoryFootprint.mb(MemoryFootprint.current()), privacy: .public)"
      )
    #endif
    return DecodedImage(cgImage: cg, exifOrientation: info.orientation)
  }
}
