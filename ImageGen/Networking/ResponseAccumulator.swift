import Foundation
import Synchronization

/// Appends response chunks to `Requests/<id>/response-<attempt>.part` synchronously in the delegate
/// callback, so they stay in order (D§4.6). A lazy open creates the file if it's missing and seeks
/// to the end; it never truncates, because a previous process may have written part of the body.
final class ResponseAccumulator: Sendable {
  private let files: FileStore
  private let handles = Mutex<[Int: FileHandle]>([:])

  init(files: FileStore) {
    self.files = files
  }

  /// The only place an empty `.part` file is created: when the task for a new attempt is made.
  func prepareNewAttempt(requestID: UUID, attempt: Int) throws {
    let part = files.partURL(requestID, attempt: attempt)
    try FileStore.createDirectory(part.deletingLastPathComponent())
    try? FileManager.default.removeItem(at: files.completeMarkerURL(requestID, attempt: attempt))
    guard FileManager.default.createFile(atPath: part.path, contents: Data(), attributes: [.protectionKey: FileStore.protection])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: part.path]) }
  }

  func append(_ data: Data, requestID: UUID, attempt: Int, taskIdentifier: Int) {
    handles.withLock { map in
      if map[taskIdentifier] == nil { map[taskIdentifier] = open(requestID: requestID, attempt: attempt) }
      try? map[taskIdentifier]?.write(contentsOf: data)
    }
  }

  /// Closes the handle and writes the `.complete` marker, holding the HTTP status (or nothing),
  /// so a crash between here and the save can be re-parsed at launch (D§4.7 step 4).
  /// Returns the `.part` file and its size. Nothing is written for a request whose folder is gone
  /// (the request was deleted).
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

  /// The HTTP status a `.complete` marker recorded, if any.
  static func markerStatus(_ url: URL) -> Int? {
    (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// Opens for appending; creates the `.part` file if it's missing, but never the request's
  /// folder, which exists for every live request (it holds `body.json`).
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
