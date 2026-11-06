import CoreTransferable
import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Transferable encapsulation of a stored original image file, declaring uniform type representations
/// and isolated file transfer semantics for system sharing and export.
struct ImageFile: Transferable, Sendable, Equatable {
  let url: URL
  let utType: UTType
  let suggestedName: String

  /// Uniform type identifier corresponding to the AVIF container format.
  static let avif = UTType("public.avif") ?? UTType(importedAs: "public.avif")

  // Declare file representations per supported image format, disallowing direct original file access.
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .jpeg) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .jpeg }
    FileRepresentation(exportedContentType: .png) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .png }
    FileRepresentation(exportedContentType: .webP) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .webP }
    FileRepresentation(exportedContentType: .heic) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .heic }
    FileRepresentation(exportedContentType: .heif) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .heif }
    FileRepresentation(exportedContentType: .gif) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == .gif }
    FileRepresentation(exportedContentType: avif) { SentTransferredFile($0.url, allowAccessingOriginalFile: false) }
      .exportingCondition { $0.utType == avif }
  }

  /// Creates an item provider for sharing or dragging the file under its suggested filename.
  var itemProvider: NSItemProvider {
    let provider = NSItemProvider()
    provider.register(self)
    provider.suggestedName = suggestedName
    return provider
  }

  /// Creates an item provider referencing a scratch copy of the asset with its suggested filename for drag operations.
  func draggedCopyProvider() -> NSItemProvider {
    guard let copy = try? ExportScratch.namedCopy(of: url, name: suggestedName) else { return NSItemProvider() }
    return NSItemProvider(object: copy as NSURL)
  }

  /// Atomically writes or replaces the target destination with stored image content.
  func write(to destination: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: destination.path) else {
      try manager.copyItem(at: url, to: destination)
      return
    }
    let holder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
    defer { try? manager.removeItem(at: holder) }
    let copy = holder.appendingPathComponent(destination.lastPathComponent)
    try manager.copyItem(at: url, to: copy)
    _ = try manager.replaceItemAt(destination, withItemAt: copy)
  }

  /// Generates a standardized, timestamped export filename incorporating asset date, truncated UUID, and format extension.
  static func suggestedName(date: Date, id: UUID, ext: String, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let stamp = String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    return "ImageGen-\(stamp)-\(id.uuidString.lowercased().prefix(6)).\(ext)"
  }

  /// Resolves the corresponding `UTType` for a given MIME type string, defaulting to JPEG for unmapped types.
  static func utType(forMime mimeType: String) -> UTType {
    switch mimeType.lowercased() {
    case "image/jpeg", "image/jpg": .jpeg
    case "image/png": .png
    case "image/webp": .webP
    case "image/heic": .heic
    case "image/heif": .heif
    case "image/gif": .gif
    case "image/avif": avif
    default: MimeTypes.utType(for: mimeType) ?? .jpeg
    }
  }
}

/// Value type encapsulating an image asset ready for export, aggregating filesystem paths, encoding metadata,
/// pixel dimensions, and telemetry formatting.
struct ExportItem: Sendable, Equatable, Identifiable {
  let id: UUID
  let url: URL
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let createdAt: Date

  var utType: UTType { ImageFile.utType(forMime: mimeType) }
  var fileExtension: String {
    let ext = url.pathExtension.lowercased()
    return ext.isEmpty ? MimeTypes.fileExtension(for: mimeType) : ext
  }
  var suggestedName: String { ImageFile.suggestedName(date: createdAt, id: id, ext: fileExtension) }
  var file: ImageFile { ImageFile(url: url, utType: utType, suggestedName: suggestedName) }

  /// Human-readable diagnostic summary describing asset dimensions, payload size, and encoding type.
  var logDescription: String {
    "img \(Format.short(id)) · \(Format.type(mimeType)) · \(Format.mb(byteCount)) · \(pixelWidth)×\(pixelHeight)"
  }
}

/// File document representation bridging disk-backed asset files to system file export presentations.
struct ImageFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.image] }
  /// Supported export uniform type identifiers validated by system save panels.
  static var writableContentTypes: [UTType] { [.jpeg, .png, .webP, .heic, .heif, .gif, .tiff, .bmp, ImageFile.avif, .image] }
  let file: ImageFile

  init(file: ImageFile) { self.file = file }

  // Opening documents from external inputs is unsupported; instances are strictly outbound export payloads.
  init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

  /// Packages the underlying image payload into a `FileWrapper` configured with standard export naming.
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let wrapper = try FileWrapper(url: file.url, options: .immediate)
    wrapper.preferredFilename = file.suggestedName
    wrapper.filename = file.suggestedName
    return wrapper
  }
}
