import Foundation

/// Utility namespace for resolving and loading static test resource fixtures bundled within the test target.
enum FixtureLoader {
  struct Missing: Error, CustomStringConvertible {
    let path: String
    var description: String { "fixture not found: \(path)" }
  }

  static var root: URL {
    Bundle(for: BundleToken.self).resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
  }

  static func url(_ path: String) throws -> URL {
    let url = root.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw Missing(path: path) }
    return url
  }

  static func data(_ path: String) throws -> Data {
    try Data(contentsOf: url(path))
  }

  static func string(_ path: String) throws -> String {
    String(decoding: try data(path), as: UTF8.self)
  }

  /// Returns sorted filenames contained within the designated subfolder of the fixtures bundle.
  static func names(in folder: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path).sorted()
  }
}
