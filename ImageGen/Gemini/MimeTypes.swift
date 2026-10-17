import Foundation
import UniformTypeIdentifiers

/// MIME type ↔ file extension and `UTType` (D§4.4).
///
/// The app stores each image under a file name with the extension of its MIME type (for example,
/// `ResponseParser` names each output file this way). `UTType` is the system's type identifier, which
/// the export code uses. A static table and pure functions: no state, safe from any thread.
enum MimeTypes {
  private static let extensions: [String: String] = [
    "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic",
    "image/heif": "heif", "image/gif": "gif", "image/avif": "avif",
  ]

  /// The extension for a MIME type; unknown image types fall back to the system's preference, then `bin`.
  static func fileExtension(for mimeType: String) -> String {
    let key = mimeType.lowercased()
    if let ext = extensions[key] { return ext }
    return UTType(mimeType: key)?.preferredFilenameExtension ?? "bin"
  }

  /// The reverse of the table only (`jpeg` counts as `jpg`); nil for any other extension.
  static func mimeType(forExtension ext: String) -> String? {
    let key = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
    return extensions.first { $0.value == key }?.key
  }

  static func utType(for mimeType: String) -> UTType? {
    UTType(mimeType: mimeType.lowercased())
  }
}
