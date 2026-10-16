import Foundation
import UniformTypeIdentifiers

/// MIME type ↔ file extension and `UTType` (D§4.4).
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

  static func mimeType(forExtension ext: String) -> String? {
    let key = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
    return extensions.first { $0.value == key }?.key
  }

  static func utType(for mimeType: String) -> UTType? {
    UTType(mimeType: mimeType.lowercased())
  }
}
