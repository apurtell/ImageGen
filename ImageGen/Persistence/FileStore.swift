import Foundation

/// Manages on-disk directory hierarchies and file operations rooted under `Application Support/ImageGen/`.
///
/// Architecture:
/// - Relational entities persist relative paths relative to the application support root, ensuring portability
///   across sandboxed container relocations during iOS updates.
/// - Transient artifacts such as thumbnails reside in dedicated cache directory hierarchies subject to OS reclamation.
/// - Operates as an immutable `Sendable` value type safely held across actor boundaries, executing synchronous I/O
///   on the caller's thread without shared file-descriptor locking.
struct FileStore: Sendable {
  let root: URL
  let thumbnailsDir: URL

  init(root: URL, cachesRoot: URL) {
    self.root = root
    self.thumbnailsDir = cachesRoot.appendingPathComponent("Thumbnails", isDirectory: true)
  }

  /// Default file protection attribute ensuring accessibility following first device authentication.
  static let protection = FileProtectionType.completeUntilFirstUserAuthentication

  var imagesDir: URL { root.appendingPathComponent("Images", isDirectory: true) }
  var requestsDir: URL { root.appendingPathComponent("Requests", isDirectory: true) }
  /// Staging container for in-flight composer attachments scoped to the current process lifetime.
  var stagingDir: URL { root.appendingPathComponent("Staging", isDirectory: true) }
  /// Archival staging location isolating orphaned artifacts from prior application runs for background reclamation.
  var retiredStagingDir: URL { root.appendingPathComponent("StagingRetired", isDirectory: true) }
  var logsDir: URL { root.appendingPathComponent("Logs", isDirectory: true) }

  func conversationDir(_ conv: UUID) -> URL {
    imagesDir.appendingPathComponent(conv.uuidString, isDirectory: true)
  }

  /// Computes the relative storage path: `Images/<conv>/<image>.<ext>`
  func imageRelativePath(conv: UUID, image: UUID, ext: String) -> String {
    "Images/\(conv.uuidString)/\(image.uuidString).\(ext)"
  }

  func imageURL(conv: UUID, image: UUID, ext: String) -> URL {
    url(relative: imageRelativePath(conv: conv, image: image, ext: ext))
  }

  /// Computes the relative storage path for scaled multi-modal inputs: `Images/<conv>/prepared/<image>-<edge>.<ext>`
  func preparedRelativePath(conv: UUID, image: UUID, edge: Int, ext: String) -> String {
    "Images/\(conv.uuidString)/prepared/\(image.uuidString)-\(edge).\(ext)"
  }

  func preparedURL(conv: UUID, image: UUID, edge: Int, ext: String) -> URL {
    url(relative: preparedRelativePath(conv: conv, image: image, edge: edge, ext: ext))
  }

  // Request directory layouts encapsulating attempt artifacts, payloads, and execution sentinels.

  func requestDir(_ request: UUID) -> URL {
    requestsDir.appendingPathComponent(request.uuidString, isDirectory: true)
  }

  func bodyURL(_ request: UUID) -> URL {
    requestDir(request).appendingPathComponent("body.json")
  }

  func partURL(_ request: UUID, attempt: Int) -> URL {
    requestDir(request).appendingPathComponent("response-\(attempt).part")
  }

  /// Completion sentinel URL recording task termination status for crash recovery reconciliation.
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

  /// Computes path relative to the store root, returning nil if outside the hierarchy.
  func relativePath(of url: URL) -> String? {
    let base = root.standardizedFileURL.path
    let full = url.standardizedFileURL.path
    guard full.hasPrefix(base + "/") else { return nil }
    return String(full.dropFirst(base.count + 1))
  }

  func exists(relative path: String) -> Bool {
    FileManager.default.fileExists(atPath: url(relative: path).path)
  }

  /// Creates a directory hierarchy configured with the standard data protection class.
  static func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
  }

  /// Moves a staged file into its canonical destination path, updating modification timestamps to reflect recent creation.
  func moveStaged(_ from: URL, to: URL) throws {
    let dir = to.deletingLastPathComponent()
    try Self.createDirectory(dir)
    if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
    do {
      try FileManager.default.moveItem(at: from, to: to)
    } catch {
      // Mitigate race condition where concurrent directory cleanup removes an empty conversation folder.
      guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: dir.path) else { throw error }
      try Self.createDirectory(dir)
      try FileManager.default.moveItem(at: from, to: to)
    }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: to.path)
  }

  /// Relocates the staging directory to retired storage at process startup, isolating stale artifacts for pruning.
  func retireStaging() {
    guard FileManager.default.fileExists(atPath: stagingDir.path) else { return }
    try? Self.createDirectory(retiredStagingDir)
    try? FileManager.default.moveItem(at: stagingDir, to: retiredStagingDir.appendingPathComponent(UUID().uuidString))
  }

  /// Duplicates an item using APFS copy-on-write clone semantics when supported.
  func cloneItem(at from: URL, to: URL) throws {
    try Self.createDirectory(to.deletingLastPathComponent())
    if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
    try FileManager.default.copyItem(at: from, to: to)
  }

  /// Purges file artifacts associated with a conversation and its member generation requests.
  func removeConversationFiles(_ conv: UUID, requestIDs: [UUID]) -> DeletionResult {
    var result = DeletionResult()
    for dir in [conversationDir(conv)] + requestIDs.map(requestDir) {
      remove(dir, into: &result)
    }
    return result
  }

  /// Removes a file or directory tree while aggregating freed storage metrics and tracking non-fatal errors.
  func remove(_ url: URL, into result: inout DeletionResult) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let (count, bytes) = Self.usage(of: url)
    do {
      try FileManager.default.removeItem(at: url)
      result.filesRemoved += count
      result.bytesFreed += bytes
    } catch CocoaError.fileNoSuchFile {
      // Concurrently removed by maintenance routine; safely ignored.
    } catch {
      result.failures += 1
      if result.firstError == nil { result.firstError = "\(url.lastPathComponent): \(error.localizedDescription)" }
    }
  }

  /// Aggregate storage allocation metrics partitioned by functional subsystem.
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

  /// Traverses a file hierarchy to compute total item count and byte consumption.
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
