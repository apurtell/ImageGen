import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Asynchronous image caching service generating and managing tiered thumbnails for UI presentation.
///
/// Architecture:
/// - Maintains multi-tiered resolution targets (240 px list/tray thumbnails and 1200 px transcript previews).
/// - Implements a three-tier retrieval hierarchy: in-memory `NSCache` with byte cost budgets, persistent disk cache
///   under `Caches/Thumbnails/`, and on-demand subsampled rasterization from original source files.
/// - Actor isolation guarantees thread safety and off-loads intensive decoding from the main UI thread,
///   employing eager bitmap rasterization to prevent scroll-time hitching.
actor ThumbnailService {
  static let listSize = 240
  static let bubbleSize = 1200

  /// Reference wrapper encapsulating CoreGraphics image objects for `NSCache` storage.
  private final class Entry {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private let directory: URL
  private let decodeTimer: DecodeTimer
  /// Cost-bounded memory cache tracking resident bitmap footprints subject to system pressure eviction.
  private let cache = NSCache<NSString, Entry>()
  /// Metric tracking thumbnail disk writes for telemetry and test validation.
  private(set) var writes = 0

  init(directory: URL, decodeTimer: DecodeTimer = DecodeTimer()) {
    self.directory = directory
    self.decodeTimer = decodeTimer
    cache.totalCostLimit = 120 * 1024 * 1024
  }

  func fileURL(id: UUID, px: Int) -> URL {
    directory.appendingPathComponent("\(id.uuidString)-\(px).jpg")
  }

  /// Resolves a thumbnail bitmap for the specified image identifier and target dimension.
  func thumbnail(for imageURL: URL, id: UUID, px: Int) async -> CGImage? {
    let key = "\(id.uuidString)-\(px)" as NSString
    if let hit = cache.object(forKey: key) { return hit.image }

    let file = fileURL(id: id, px: px)
    if FileManager.default.fileExists(atPath: file.path),
      let source = CGImageSourceCreateWithURL(file as CFURL, ImageInspector.noCache),
      let image = decodeTimer.measure("thumbnail \(px)", {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      })
    {
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return remember(image, key)
    }

    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, ImageInspector.noCache),
      let image = try? decodeTimer.measure("thumbnail \(px)", { try ImagePreprocessor.downscale(source, to: px) })
    else { return nil }
    let out = (image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
      ? image : ((try? ImagePreprocessor.flattened(image)) ?? image)
    if (try? ImagePreprocessor.write(out, to: file, type: .jpeg, quality: 0.85)) != nil { writes += 1 }
    return remember(out, key)
  }

  /// Flushes in-memory image allocations while retaining persistent disk representations.
  func removeFromMemory() {
    cache.removeAllObjects()
  }

  private func remember(_ image: CGImage, _ key: NSString) -> CGImage {
    cache.setObject(Entry(image), forKey: key, cost: image.width * image.height * 4)
    return image
  }
}
