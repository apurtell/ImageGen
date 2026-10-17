import Foundation
import UniformTypeIdentifiers

/// Utility providing bidirectional mapping between MIME type strings, file path extensions, and system `UTType` identifiers.
enum MimeTypes {
  private static let extensions: [String: String] = [
    "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic",
    "image/heif": "heif", "image/gif": "gif", "image/avif": "avif",
  ]

  /// Resolves the canonical file extension for a MIME type string, falling back to system UTType preferences or generic binary.
  static func fileExtension(for mimeType: String) -> String {
    let key = mimeType.lowercased()
    if let ext = extensions[key] { return ext }
    return UTType(mimeType: key)?.preferredFilenameExtension ?? "bin"
  }

  /// Resolves the corresponding MIME type for a given file extension string.
  static func mimeType(forExtension ext: String) -> String? {
    let key = ext.lowercased() == "jpeg" ? "jpg" : ext.lowercased()
    return extensions.first { $0.value == key }?.key
  }

  static func utType(for mimeType: String) -> UTType? {
    UTType(mimeType: mimeType.lowercased())
  }
}
