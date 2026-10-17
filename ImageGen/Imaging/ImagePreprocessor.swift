import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares uploads for the API (D§4.8 step 3): always re-encodes, so EXIF and GPS are stripped
/// and orientation is applied; never upscales; decodes with subsampling, never in full.
///
/// It sits in the imaging layer. The chat screen calls `prepare` when an item lands in the tray, and
/// `RequestPreparer` calls it to re-prepare an upload and calls `shrink` (through `BudgetPlanner`) to fit
/// the body budget. `ThumbnailService` reuses `downscale`, `flattened` and `write`.
///
/// Concurrency model. The type holds no state. `prepare` and `shrink` are `@concurrent`, so the slow
/// decode and encode run in the background, off the caller's actor, and several can run at the same
/// time. `write` makes each file appear in one atomic rename, so two calls that write the same name
/// leave one whole file, never a mix.
enum ImagePreprocessor {
  static let jpegQuality = 0.9

  /// Writes `destinationDir/<id>-<maxLongEdge>.<jpg|png>`. The name carries the setting, not the
  /// pixel size, so a smaller source keeps the setting in its name.
  /// `@concurrent` runs this `async` function in the background (see the primer, *Tasks and cancellation*).
  @concurrent
  static func prepare(source: URL, maxLongEdge: Int, destinationDir: URL, id: UUID) async throws -> PreparedImage {
    // DEBUG only: log the memory footprint before and after, to confirm the subsampled decode (D§8).
    // `defer` runs the log when the function exits, on every path.
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
    // Output type (D§4.8): HEIC/HEIF is always JPEG; a PNG or WebP with alpha stays PNG; all else is JPEG.
    let heif = isHEIF(info.utType)
    let keepPNG = !heif && info.hasAlpha && (info.utType == UTType.png.identifier || info.utType == UTType.webP.identifier)
    // Cancellation is checked between the steps (a tray item removed meanwhile cancels its task):
    // a step that has started runs to its end, but nothing more is decoded, encoded or written.
    try Task.checkCancellation()
    let image = try downscale(src, to: min(maxLongEdge, info.longEdge))
    try Task.checkCancellation()
    let url = destinationDir.appendingPathComponent("\(id.uuidString)-\(maxLongEdge).\(keepPNG ? "png" : "jpg")")
    if keepPNG {
      try write(image, to: url, type: .png, quality: nil)
    } else {
      // JPEG has no alpha, so draw an image with alpha onto white first.
      try write(info.hasAlpha ? flattened(image) : image, to: url, type: .jpeg, quality: jpegQuality)
    }
    return try described(url, mimeType: keepPNG ? "image/png" : "image/jpeg", longEdgeSetting: maxLongEdge)
  }

  /// Re-prepares at `factor ×` the current long edge (D§4.8 step 5), as JPEG at `quality` with any
  /// alpha flattened onto white (or keeping PNG when `flattenAlpha` is false and it was PNG).
  /// Writes next to the input, named for the new edge. It does not remove the input file.
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
    // `-s<edge>`, not `-<edge>`: `prepare` names its files `<id>-<setting>` in the same folder, so a
    // later setting equal to this edge would otherwise overwrite this file, which an older request's
    // record may point to (Regenerate would then send different bytes).
    let url = input.url.deletingLastPathComponent().appendingPathComponent(
      "\(stem(of: input.url))-s\(edge).\(keepPNG ? "png" : "jpg")")
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
  /// The "thumbnail" API is how ImageIO decodes at a reduced size: it reads only enough of the file
  /// for `maxPixelSize`. "Cache immediately" decodes now, on this thread, and not lazily at the first
  /// draw (see the primer, *Images*).
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

  /// Draws the image onto white, dropping alpha. It keeps the source's color space when it is RGB,
  /// else uses sRGB.
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
  /// The image goes to a temporary file in the same folder, then a rename puts it in place in one
  /// step: a process killed mid-write leaves no truncated image under the real name (which a
  /// reader would decode partially, and the thumbnail cache would keep serving).
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
    // `rename` (the POSIX call) replaces any file at `url` in one step, so a reader sees the old file
    // or the new one, never a mix.
    guard CGImageDestinationFinalize(dest), rename(temp.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temp)  // Nothing else refers to the temporary file.
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
  }

  /// Reads back the written file's size and dimensions, so the result describes the bytes on disk.
  private static func described(_ url: URL, mimeType: String, longEdgeSetting: Int) throws -> PreparedImage {
    let info = try ImageInspector.inspect(url: url)
    let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    return PreparedImage(
      url: url, mimeType: mimeType, byteCount: bytes, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
      longEdgeSetting: longEdgeSetting)
  }

  /// `<id>-2048.jpg` (prepared) or `<id>-s1536.jpg` (shrunk) → `<id>`; anything else keeps its name
  /// without the extension. A shrink of a shrunk file is named from the same stem.
  static func stem(of url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    guard let dash = name.lastIndex(of: "-") else { return name }
    var suffix = name[name.index(after: dash)...]
    if suffix.first == "s" { suffix = suffix.dropFirst() }
    return !suffix.isEmpty && Int(suffix) != nil ? String(name[..<dash]) : name
  }
}
