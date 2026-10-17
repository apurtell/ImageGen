import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 240 px (list, tray) and 1200 px (bubble) JPEG thumbnails, made on first request, stored as
/// `Caches/Thumbnails/<id>-<px>.jpg` and kept in a 120 MB memory cache (D§8).
///
/// It sits in the imaging layer. The image views, the tray and the viewer ask it for thumbnails;
/// `GenerationService` asks for a new output's thumbnails right after the parse, while the bytes are hot.
/// A lookup tries three places in order: the memory cache, the file on disk, then the original image.
///
/// Concurrency model. It is an actor (see the primer, *Actors*), so it never runs on the main thread,
/// and its decodes never stall scrolling. `thumbnail(for:id:px:)` has no `await` inside, so each call
/// runs as one step: two requests for the same thumbnail never make it twice, and the cache and the
/// `writes` counter need no lock. The cost is that decodes run one at a time. The Janitor trims the
/// disk folder at the same time; a file it removes is made again on the next request.
actor ThumbnailService {
  static let listSize = 240
  static let bubbleSize = 1200

  /// `NSCache` stores objects only, so this class boxes the `CGImage`.
  private final class Entry {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private let directory: URL
  private let decodeTimer: DecodeTimer
  /// Evicts by cost (bytes of the decoded bitmap) when over its limit, and on memory pressure.
  private let cache = NSCache<NSString, Entry>()
  /// Thumbnail files written, for tests.
  private(set) var writes = 0

  init(directory: URL, decodeTimer: DecodeTimer = DecodeTimer()) {
    self.directory = directory
    self.decodeTimer = decodeTimer
    cache.totalCostLimit = 120 * 1024 * 1024
  }

  func fileURL(id: UUID, px: Int) -> URL {
    directory.appendingPathComponent("\(id.uuidString)-\(px).jpg")
  }

  /// nil when the image can't be read. `px` is the long edge of the thumbnail, in pixels.
  func thumbnail(for imageURL: URL, id: UUID, px: Int) async -> CGImage? {
    let key = "\(id.uuidString)-\(px)" as NSString
    if let hit = cache.object(forKey: key) { return hit.image }

    let file = fileURL(id: id, px: px)
    if FileManager.default.fileExists(atPath: file.path),
      let source = CGImageSourceCreateWithURL(file as CFURL, ImageInspector.noCache),
      // Decoded here, off the main thread. Without "cache immediately" ImageIO returns an image that
      // decodes lazily, the first time it is drawn: on the main thread, while scrolling.
      let image = decodeTimer.measure("thumbnail \(px)", {
        CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      })
    {
      // Marks it recently used for the Janitor's LRU trim.
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)  // A failure only changes the eviction order.
      return remember(image, key)
    }

    // No usable file: make one from the original. `downscale` decodes with subsampling and applies the
    // orientation, so a large photo never decodes in full (D§8). It also decodes eagerly.
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, ImageInspector.noCache),
      let image = try? decodeTimer.measure("thumbnail \(px)", { try ImagePreprocessor.downscale(source, to: px) })  // Unreadable original: no thumbnail.
    else { return nil }
    // JPEG has no alpha, so an image with alpha is drawn onto white first.
    let out = (image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
      ? image : ((try? ImagePreprocessor.flattened(image)) ?? image)  // On failure, keep the unflattened image.
    // The write is atomic (`ImagePreprocessor.write`), so a later read never sees a partial file.
    if (try? ImagePreprocessor.write(out, to: file, type: .jpeg, quality: 0.85)) != nil { writes += 1 }  // A failed write only costs a decode next time.
    return remember(out, key)
  }

  /// Empties the memory cache; the files on disk stay. Settings calls it when it clears the thumbnail
  /// cache and after Delete All Chats.
  func removeFromMemory() {
    cache.removeAllObjects()
  }

  private func remember(_ image: CGImage, _ key: NSString) -> CGImage {
    cache.setObject(Entry(image), forKey: key, cost: image.width * image.height * 4)
    return image
  }
}
