import Foundation

/// Scoped temporary directory fixture providing isolated filesystem scratch space, automatically purged on deallocation.
final class TestFileRoot: Sendable {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ImageGenTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// Resolves a file URL within the temporary tree, ensuring intermediate ancestor directories are created.
  func file(_ relativePath: String) -> URL {
    let file = url.appendingPathComponent(relativePath)
    try! FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    return file
  }

  /// Creates and returns a subdirectory URL located within the temporary root.
  func directory(_ relativePath: String) -> URL {
    let dir = url.appendingPathComponent(relativePath, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
