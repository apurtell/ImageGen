import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Asynchronous image caching service generating and managing tiered thumbnails for UI presentation.
///
/// Architecture:
/// - Maintains multi-tiered resolution targets (240 px list/tray thumbnails, 1200 px standard previews, and
///   adaptive high-resolution display buckets up to 4096 px for expanded viewing contexts).
/// - Implements a three-tier retrieval hierarchy: non-isolated thread-safe in-memory `NSCache` with byte-cost budgets,
///   persistent disk storage in `Caches/Thumbnails/`, and asynchronous downsampled decoding from source assets.
/// - Off-actor decoding execution with isolated concurrency lanes partitioning standard previews from high-resolution decodes,
///   preventing heavy rasterization tasks from blocking interactive navigation or thumbnail cache hits.
actor ThumbnailService {
  static let listSize = 240
  static let bubbleSize = 1200
  /// Discrete resolution buckets for high-resolution display rendering, minimizing redundant rasterization across continuous view resizes.
  static let displayBuckets = [bubbleSize, 1800, 2400, 3200, 4096]

  /// Resolves target long-edge pixel dimensions corresponding to rendered point geometry and screen scale.
  /// Bounds requests between baseline preview dimensions (bubbleSize) and original source dimensions, selecting the closest enclosing display bucket.
  static func displayPixels(displayed: CGSize, scale: CGFloat, originalLongEdge: Int) -> Int {
    let needed = max(displayed.width, displayed.height) * scale
    let bucket = displayBuckets.first { CGFloat($0) >= needed } ?? displayBuckets[displayBuckets.count - 1]
    return max(min(bucket, originalLongEdge), bubbleSize)
  }

  /// Reference wrapper encapsulating CoreGraphics image objects for `NSCache` storage.
  private final class Entry {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  /// Serial dispatch queue managing bounded concurrent decoding operations.
  private struct DecodeLane {
    var isBusy = false
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  private let directory: URL
  private let decodeTimer: DecodeTimer
  /// Thread-safe in-memory bitmap cache indexed by asset identifier and target resolution, allowing lock-free reads across threads.
  private nonisolated(unsafe) let cache = NSCache<NSString, Entry>()
  /// Tracks cached resolution tiers per asset identifier to coordinate targeted cache evictions.
  private var cachedSizes: [UUID: Set<Int>] = [:]
  /// Dedicated concurrency lanes isolating baseline preview decodes from high-resolution rasterization.
  private var decodeLanes = [DecodeLane(), DecodeLane()]
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
    if let hit = cachedThumbnail(id: id, px: px) { return hit }
    let lane = px > Self.bubbleSize ? 1 : 0
    await enter(lane)
    defer { leave(lane) }
    // Re-evaluate in-memory cache following serialization queue acquisition.
    if let hit = cachedThumbnail(id: id, px: px) { return hit }
    if Task.isCancelled { return nil }
    guard let made = await Self.make(from: imageURL, file: fileURL(id: id, px: px), px: px, timer: decodeTimer) else { return nil }
    if made.wasWritten { writes += 1 }
    return remember(made.image, id: id, px: px)
  }

  /// Synchronously inspects in-memory cache for an exact dimension match without dispatching decode work.
  nonisolated func cachedThumbnail(id: UUID, px: Int) -> CGImage? {
    cache.object(forKey: Self.key(id, px))?.image
  }

  /// Locates the smallest in-memory thumbnail meeting or exceeding requested dimension thresholds.
  nonisolated func cachedThumbnail(id: UUID, atLeast px: Int, originalLongEdge: Int) -> (image: CGImage, px: Int)? {
    let sizes = Set(Self.displayBuckets.map { max(min($0, originalLongEdge), Self.bubbleSize) }).filter { $0 >= px }
    for size in sizes.sorted() {
      if let image = cachedThumbnail(id: id, px: size) { return (image, size) }
    }
    return nil
  }

  /// Evicts cached in-memory entries and deletes backing disk files for specified image identifiers.
  func remove(imageIDs: Set<UUID>) async {
    for id in imageIDs {
      for px in cachedSizes.removeValue(forKey: id) ?? [] { cache.removeObject(forKey: Self.key(id, px)) }
    }
    await Self.removeFiles(of: imageIDs, in: directory)
  }

  /// Prunes on-disk thumbnail files corresponding to specified image identifiers.
  @concurrent
  private static func removeFiles(of imageIDs: Set<UUID>, in directory: URL) async {
    guard !imageIDs.isEmpty else { return }
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for file in files where imageID(ofFile: file).map(imageIDs.contains) == true {
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// Extracts the backing image asset identifier from a thumbnail disk file path.
  nonisolated static func imageID(ofFile url: URL) -> UUID? {
    UUID(uuidString: String(url.lastPathComponent.prefix(36)))
  }

  private nonisolated static func key(_ id: UUID, _ px: Int) -> NSString { "\(id.uuidString)-\(px)" as NSString }

  /// Acquires execution lock for the designated decode lane, suspending if busy.
  private func enter(_ lane: Int) async {
    guard decodeLanes[lane].isBusy else {
      decodeLanes[lane].isBusy = true
      return
    }
    await withCheckedContinuation { decodeLanes[lane].waiting.append($0) }
  }

  /// Releases decode lane lock, resuming the next queued continuation.
  private func leave(_ lane: Int) {
    if decodeLanes[lane].waiting.isEmpty {
      decodeLanes[lane].isBusy = false
    } else {
      decodeLanes[lane].waiting.removeFirst().resume()
    }
  }

  /// Resolves thumbnail bitmap via existing disk cache or downsamples from source asset, persisting results to disk.
  @concurrent
  private static func make(from imageURL: URL, file: URL, px: Int, timer: DecodeTimer) async -> (image: CGImage, wasWritten: Bool)? {
    if FileManager.default.fileExists(atPath: file.path),
      let source = CGImageSourceCreateWithURL(file as CFURL, ImageInspector.noCache),
      let image = timer.measure("thumbnail \(px)", {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      })
    {
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return (image, false)
    }
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, ImageInspector.noCache),
      let image = try? timer.measure("thumbnail \(px)", { try ImagePreprocessor.downscale(source, to: px) })
    else { return nil }
    let out = (image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
      ? image : ((try? ImagePreprocessor.flattened(image)) ?? image)
    let wasWritten = (try? ImagePreprocessor.write(out, to: file, type: .jpeg, quality: 0.85)) != nil
    return (out, wasWritten)
  }

  /// Flushes in-memory image allocations while retaining persistent disk representations.
  func removeFromMemory() {
    cache.removeAllObjects()
    cachedSizes = [:]
  }

  private func remember(_ image: CGImage, id: UUID, px: Int) -> CGImage {
    cache.setObject(Entry(image), forKey: Self.key(id, px), cost: image.width * image.height * 4)
    cachedSizes[id, default: []].insert(px)
    return image
  }
}
