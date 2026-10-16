import CoreTransferable
import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// A stored original, exported as is (D§4.9). `transferRepresentation` is static, so it declares
/// one representation per type the app stores, each gated on the instance's type: exactly one
/// applies, and it carries the real type and the original bytes.
struct ImageFile: Transferable, Sendable, Equatable {
  let url: URL
  let utType: UTType
  let suggestedName: String

  static let avif = UTType("public.avif") ?? UTType(importedAs: "public.avif")

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

  /// `ImageGen-2026-10-15-1432-7f3a9c.jpg`.
  static func suggestedName(date: Date, id: UUID, ext: String, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let stamp = String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    return "ImageGen-\(stamp)-\(id.uuidString.lowercased().prefix(6)).\(ext)"
  }

  /// The stored types; anything unknown is treated as JPEG, the type the app writes most.
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

/// An image to export, with what the log states about it (D§4.13).
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

  /// "img 7f3a · JPEG · 0.4 MB · 2752×1536"
  var logDescription: String {
    "img \(Format.short(id)) · \(Format.type(mimeType)) · \(Format.mb(byteCount)) · \(pixelWidth)×\(pixelHeight)"
  }
}

/// Save to Files' document (D§4.9): the original file's bytes in a `FileWrapper` named with the
/// suggested name. `.fileExporter` with the `Transferable` item crashed on iOS 26.5 (an empty
/// `NSFileWrapper.preferredFilename` inside SwiftUI), so the exporter takes this instead.
struct ImageFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.image] }
  let file: ImageFile

  init(file: ImageFile) { self.file = file }

  init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let wrapper = try FileWrapper(url: file.url, options: .immediate)
    wrapper.preferredFilename = file.suggestedName
    wrapper.filename = file.suggestedName
    return wrapper
  }
}
