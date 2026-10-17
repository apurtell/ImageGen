import Foundation
import Synchronization

/// Streams incoming HTTP response chunks directly to disk files (`response-<attempt>.part`) synchronously
/// within URLSession delegate callbacks to preserve strict payload ordering and minimize memory overhead.
///
/// File management semantics:
/// - Lazy handle allocation opens files on-demand and seeks to end-of-file, accommodating segmented transfers across process boundaries.
/// - Upon transfer completion, emits a `.complete` sentinel file containing status metadata to enable restart reconciliation.
/// - Thread safety is ensured via a `Mutex` guarding the active descriptor lookup table across concurrent invocations.
final class ResponseAccumulator: Sendable {
  private let files: FileStore
  /// Active file descriptor handles keyed by URLSession task identifier.
  private let handles = Mutex<[Int: FileHandle]>([:])

  init(files: FileStore) {
    self.files = files
  }

  /// Initializes an empty `.part` artifact and purges stale completion sentinels prior to attempt launch.
  func prepareNewAttempt(requestID: UUID, attempt: Int) throws {
    let part = files.partURL(requestID, attempt: attempt)
    try FileStore.createDirectory(part.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: files.completeMarkerURL(requestID, attempt: attempt))
    guard FileManager.default.createFile(atPath: part.path, contents: Data(), attributes: [.protectionKey: FileStore.protection])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: part.path]) }
  }

  /// Appends streamed data chunks sequentially to the on-disk attempt payload file.
  func append(_ data: Data, requestID: UUID, attempt: Int, taskIdentifier: Int) {
    handles.withLock { map in
      if map[taskIdentifier] == nil { map[taskIdentifier] = open(requestID: requestID, attempt: attempt) }
      try? map[taskIdentifier]?.write(contentsOf: data)
    }
  }

  /// Finalizes the stream by closing open descriptors and persisting the `.complete` status sentinel.
  /// Returns the target part URL and total written byte count.
  func complete(requestID: UUID, attempt: Int, taskIdentifier: Int, httpStatus: Int?) -> (url: URL, bytes: Int) {
    let part = files.partURL(requestID, attempt: attempt)
    handles.withLock { map in
      let handle = map.removeValue(forKey: taskIdentifier) ?? open(requestID: requestID, attempt: attempt)
      try? handle?.close()
    }
    let marker = files.completeMarkerURL(requestID, attempt: attempt)
    if FileManager.default.fileExists(atPath: files.requestDir(requestID).path) {
      FileManager.default.createFile(
        atPath: marker.path, contents: Data((httpStatus.map(String.init) ?? "").utf8),
        attributes: [.protectionKey: FileStore.protection])
    }
    let bytes = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return (part, bytes)
  }

  /// Extracts the cached HTTP status recorded in a completion sentinel file, if present.
  static func markerStatus(_ url: URL) -> Int? {
    (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// Resolves or initializes an append-mode file handle for an active request attempt directory.
  private func open(requestID: UUID, attempt: Int) -> FileHandle? {
    let part = files.partURL(requestID, attempt: attempt)
    guard FileManager.default.fileExists(atPath: files.requestDir(requestID).path) else { return nil }
    if !FileManager.default.fileExists(atPath: part.path) {
      FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.protectionKey: FileStore.protection])
    }
    guard let handle = try? FileHandle(forWritingTo: part) else { return nil }
    _ = try? handle.seekToEnd()
    return handle
  }
}
