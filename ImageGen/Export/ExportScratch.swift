import Foundation

/// Transient scratch directory managing temporary file copies for drag-and-drop, system shares, and diagnostics exports.
///
/// Isolated within a dedicated temporary subdirectory cleared during process launch and diagnostic log resets
/// to prevent accumulation of sensitive prompt and image artifacts.
enum ExportScratch {
  static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ImageGenExports", isDirectory: true) }

  /// Allocates a unique scratch subdirectory for an export transaction.
  static func newFolder() throws -> URL {
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Creates a named duplicate of the source file within an isolated scratch directory.
  static func namedCopy(of url: URL, name: String) throws -> URL {
    let copy = try newFolder().appendingPathComponent(name)
    try FileManager.default.copyItem(at: url, to: copy)
    return copy
  }

  /// Purges all temporary scratch export directories and cached files.
  static func sweep() {
    try? FileManager.default.removeItem(at: root)
  }
}
