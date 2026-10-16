import Foundation

/// The file layout under `Application Support/ImageGen/` (D§4.4). Paths stored in the model are
/// relative to `root`. Thumbnails live under a separate caches root.
struct FileStore: Sendable {
  let root: URL
  let thumbnailsDir: URL

  init(root: URL, cachesRoot: URL) {
    self.root = root
    self.thumbnailsDir = cachesRoot.appendingPathComponent("Thumbnails", isDirectory: true)
  }

  static let protection = FileProtectionType.completeUntilFirstUserAuthentication

  // MARK: Layout

  var imagesDir: URL { root.appendingPathComponent("Images", isDirectory: true) }
  var requestsDir: URL { root.appendingPathComponent("Requests", isDirectory: true) }
  var stagingDir: URL { root.appendingPathComponent("Staging", isDirectory: true) }
  /// Earlier launches' `Staging/` folders, each renamed here at launch for the Janitor to remove.
  var retiredStagingDir: URL { root.appendingPathComponent("StagingRetired", isDirectory: true) }
  var logsDir: URL { root.appendingPathComponent("Logs", isDirectory: true) }

  func conversationDir(_ conv: UUID) -> URL {
    imagesDir.appendingPathComponent(conv.uuidString, isDirectory: true)
  }

  /// `Images/<conv>/<image>.<ext>`
  func imageRelativePath(conv: UUID, image: UUID, ext: String) -> String {
    "Images/\(conv.uuidString)/\(image.uuidString).\(ext)"
  }

  func imageURL(conv: UUID, image: UUID, ext: String) -> URL {
    url(relative: imageRelativePath(conv: conv, image: image, ext: ext))
  }

  /// `Images/<conv>/prepared/<image>-<edge>.<ext>`
  func preparedRelativePath(conv: UUID, image: UUID, edge: Int, ext: String) -> String {
    "Images/\(conv.uuidString)/prepared/\(image.uuidString)-\(edge).\(ext)"
  }

  func preparedURL(conv: UUID, image: UUID, edge: Int, ext: String) -> URL {
    url(relative: preparedRelativePath(conv: conv, image: image, edge: edge, ext: ext))
  }

  func requestDir(_ request: UUID) -> URL {
    requestsDir.appendingPathComponent(request.uuidString, isDirectory: true)
  }

  func bodyURL(_ request: UUID) -> URL {
    requestDir(request).appendingPathComponent("body.json")
  }

  func partURL(_ request: UUID, attempt: Int) -> URL {
    requestDir(request).appendingPathComponent("response-\(attempt).part")
  }

  func completeMarkerURL(_ request: UUID, attempt: Int) -> URL {
    requestDir(request).appendingPathComponent("response-\(attempt).complete")
  }

  func outputDir(_ request: UUID, attempt: Int) -> URL {
    requestDir(request).appendingPathComponent("out-\(attempt)", isDirectory: true)
  }

  func stagingURL(_ id: UUID, ext: String) -> URL {
    stagingDir.appendingPathComponent("\(id.uuidString).\(ext)")
  }

  func url(relative path: String) -> URL {
    root.appendingPathComponent(path)
  }

  /// The path relative to `root`, or nil for a URL outside it.
  func relativePath(of url: URL) -> String? {
    let base = root.standardizedFileURL.path
    let full = url.standardizedFileURL.path
    guard full.hasPrefix(base + "/") else { return nil }
    return String(full.dropFirst(base.count + 1))
  }

  func exists(relative path: String) -> Bool {
    FileManager.default.fileExists(atPath: url(relative: path).path)
  }

  // MARK: Operations

  /// Creates a directory (and its parents) with the store's protection class.
  static func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
  }

  /// Moves a staged file into place (a rename on the same volume) and marks it modified now: a
  /// rename or clone keeps the source's date, and the Janitor spares only recently modified files
  /// that no record references yet.
  func moveStaged(_ from: URL, to: URL) throws {
    let dir = to.deletingLastPathComponent()
    try Self.createDirectory(dir)
    if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
    do {
      try FileManager.default.moveItem(at: from, to: to)
    } catch {
      // The Janitor removed the (empty) folder between the two steps: make it again, once.
      guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: dir.path) else { throw error }
      try Self.createDirectory(dir)
      try FileManager.default.moveItem(at: from, to: to)
    }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: to.path)  // Only the Janitor's freshness test reads it.
  }

  /// Renames this launch's `Staging/` (anything in it belongs to an earlier process: trays aren't
  /// kept across launches) into `StagingRetired/`, before any screen can stage a file. The Janitor
  /// later removes only retired folders, so it can never take a file this launch staged.
  func retireStaging() {
    guard FileManager.default.fileExists(atPath: stagingDir.path) else { return }
    // On failure the files stay in Staging/; the next launch retires them.
    try? Self.createDirectory(retiredStagingDir)
    try? FileManager.default.moveItem(at: stagingDir, to: retiredStagingDir.appendingPathComponent(UUID().uuidString))
  }

  /// Copies a file; on APFS this is a clone, so it costs no space until one side changes.
  func cloneItem(at from: URL, to: URL) throws {
    try Self.createDirectory(to.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
    try FileManager.default.copyItem(at: from, to: to)
  }

  /// Removes `Images/<conv>/` and each of the given `Requests/<id>/` folders.
  func removeConversationFiles(_ conv: UUID, requestIDs: [UUID]) -> DeletionResult {
    var result = DeletionResult()
    for dir in [conversationDir(conv)] + requestIDs.map(requestDir) {
      remove(dir, into: &result)
    }
    return result
  }

  /// Removes a file or folder, counting the regular files and bytes it held.
  func remove(_ url: URL, into result: inout DeletionResult) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let (count, bytes) = Self.usage(of: url)
    do {
      try FileManager.default.removeItem(at: url)
      result.filesRemoved += count
      result.bytesFreed += bytes
    } catch CocoaError.fileNoSuchFile {
      // Removed by someone else meanwhile (the Janitor and a delete overlapping): the goal is met.
    } catch {
      result.failures += 1
      if result.firstError == nil { result.firstError = "\(url.lastPathComponent): \(error.localizedDescription)" }
    }
  }

  struct Sizes: Sendable, Equatable {
    var images: Int64 = 0
    var requests: Int64 = 0
    var staging: Int64 = 0
    var thumbnails: Int64 = 0
    var logs: Int64 = 0
  }

  func sizes() -> Sizes {
    Sizes(
      images: Self.usage(of: imagesDir).bytes, requests: Self.usage(of: requestsDir).bytes,
      staging: Self.usage(of: stagingDir).bytes, thumbnails: Self.usage(of: thumbnailsDir).bytes,
      logs: Self.usage(of: logsDir).bytes)
  }

  /// Regular files and their total bytes in a file or folder tree.
  static func usage(of url: URL) -> (count: Int, bytes: Int64) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
    if !isDir.boolValue {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return (1, Int64(size))
    }
    var count = 0
    var bytes: Int64 = 0
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
      for case let file as URL in e {
        guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
        count += 1
        bytes += Int64(v.fileSize ?? 0)
      }
    }
    return (count, bytes)
  }
}
