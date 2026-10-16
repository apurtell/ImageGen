import Foundation

/// A per-test temporary directory, removed in `deinit`. Keep the instance alive for the test's duration.
final class TestFileRoot: Sendable {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageGenTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// A path under the root; intermediate directories are created.
  func file(_ relativePath: String) -> URL {
    let file = url.appendingPathComponent(relativePath)
    try! FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    return file
  }

  /// A directory under the root, created.
  func directory(_ relativePath: String) -> URL {
    let dir = url.appendingPathComponent(relativePath, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
