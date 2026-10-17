import Foundation
import Synchronization

/// Appends response chunks to `Requests/<id>/response-<attempt>.part` synchronously in the delegate
/// callback, so they stay in order (D§4.6). A lazy open creates the file if it's missing and seeks
/// to the end; it never truncates, because a previous process may have written part of the body.
///
/// `URLSessionTransport` owns one accumulator and calls it from its delegate callbacks. The handle
/// map is in memory only, so a body split across a relaunch reopens its file in the new process.
///
/// Concurrency: the transport's delegate queue is serial, so in production the callbacks do not overlap.
/// The compiler cannot see that guarantee, so a `Mutex` protects the handle map (see the primer, *Locks*).
/// The class is `Sendable` because its only mutable state is behind that `Mutex`.
final class ResponseAccumulator: Sendable {
  private let files: FileStore
  /// Open file handles, keyed by task identifier.
  private let handles = Mutex<[Int: FileHandle]>([:])

  init(files: FileStore) {
    self.files = files
  }

  /// The only place an empty `.part` file is created: when the task for a new attempt is made.
  func prepareNewAttempt(requestID: UUID, attempt: Int) throws {
    let part = files.partURL(requestID, attempt: attempt)
    try FileStore.createDirectory(part.deletingLastPathComponent())
    // Usually there's no marker yet; a stale one from an earlier run must not survive.
    try? FileManager.default.removeItem(at: files.completeMarkerURL(requestID, attempt: attempt))  // Fails harmlessly when there is no marker.
    guard FileManager.default.createFile(atPath: part.path, contents: Data(), attributes: [.protectionKey: FileStore.protection])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: part.path]) }
  }

  /// Called for each chunk from `didReceive data`. The write happens before the callback returns, so the
  /// next chunk cannot overtake it. A per-chunk `Task` would lose that order.
  func append(_ data: Data, requestID: UUID, attempt: Int, taskIdentifier: Int) {
    handles.withLock { map in
      if map[taskIdentifier] == nil { map[taskIdentifier] = open(requestID: requestID, attempt: attempt) }
      try? map[taskIdentifier]?.write(contentsOf: data)  // A lost chunk shows up as a parse failure later.
    }
  }

  /// Closes the handle and writes the `.complete` marker, holding the HTTP status (or nothing),
  /// so a crash between here and the save can be re-parsed at launch (D§4.7 step 4).
  /// Returns the `.part` file and its size. Nothing is written for a request whose folder is gone
  /// (the request was deleted).
  func complete(requestID: UUID, attempt: Int, taskIdentifier: Int, httpStatus: Int?) -> (url: URL, bytes: Int) {
    let part = files.partURL(requestID, attempt: attempt)
    handles.withLock { map in
      // No handle in the map: the body arrived in an earlier process, or no data came at all. The open
      // still creates the `.part` file, so the parser always finds one.
      let handle = map.removeValue(forKey: taskIdentifier) ?? open(requestID: requestID, attempt: attempt)
      try? handle?.close()  // The data is already written; a close error loses nothing.
    }
    let marker = files.completeMarkerURL(requestID, attempt: attempt)
    if FileManager.default.fileExists(atPath: files.requestDir(requestID).path) {
      FileManager.default.createFile(
        atPath: marker.path, contents: Data((httpStatus.map(String.init) ?? "").utf8),
        attributes: [.protectionKey: FileStore.protection])
    }
    let bytes = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0  // A missing file counts as 0 bytes.
    return (part, bytes)
  }

  /// The HTTP status a `.complete` marker recorded, if any.
  static func markerStatus(_ url: URL) -> Int? {
    (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }  // No marker, or no status: nil.
  }

  /// Opens for appending; creates the `.part` file if it's missing, but never the request's
  /// folder, which exists for every live request (it holds `body.json`).
  /// Called only while the caller holds the `handles` lock.
  private func open(requestID: UUID, attempt: Int) -> FileHandle? {
    let part = files.partURL(requestID, attempt: attempt)
    // A missing folder means that the request was deleted. Making it again would leave files that no
    // record owns.
    guard FileManager.default.fileExists(atPath: files.requestDir(requestID).path) else { return nil }
    if !FileManager.default.fileExists(atPath: part.path) {
      FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.protectionKey: FileStore.protection])
    }
    guard let handle = try? FileHandle(forWritingTo: part) else { return nil }  // No handle: the chunks are dropped.
    _ = try? handle.seekToEnd()  // A seek on a local file does not fail in practice.
    return handle
  }
}
