import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 240 px (list, tray) and 1200 px (bubble) JPEG thumbnails, made on first request, stored as
/// `Caches/Thumbnails/<id>-<px>.jpg` and kept in a 120 MB memory cache (D§8).
actor ThumbnailService {
  static let listSize = 240
  static let bubbleSize = 1200

  private final class Entry {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private let directory: URL
  private let decodeTimer: DecodeTimer
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

  /// nil when the image can't be read.
  func thumbnail(for imageURL: URL, id: UUID, px: Int) async -> CGImage? {
    let key = "\(id.uuidString)-\(px)" as NSString
    if let hit = cache.object(forKey: key) { return hit.image }

    let file = fileURL(id: id, px: px)
    if let source = CGImageSourceCreateWithURL(file as CFURL, ImageInspector.noCache),
      let image = decodeTimer.measure("thumbnail \(px)", { CGImageSourceCreateImageAtIndex(source, 0, nil) })
    {
      // Marks it recently used for the Janitor's LRU trim.
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

  func removeFromMemory() {
    cache.removeAllObjects()
  }

  private func remember(_ image: CGImage, _ key: NSString) -> CGImage {
    cache.setObject(Entry(image), forKey: key, cost: image.width * image.height * 4)
    return image
  }
}
