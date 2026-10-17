import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Handles file staging from system document pickers within active security scoped resource lifecycles.
enum FileImport {
  struct Unreadable: LocalizedError {
    var errorDescription: String? { "The file couldn't be read." }
  }

  /// Duplicates external security scoped file resources into local staging storage while ensuring
  /// resource access scopes are cleanly relinquished upon completion or error.
  static func copySecurityScoped(_ url: URL, into dir: URL, id: UUID) throws -> URL {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
    let destination = dir.appendingPathComponent("\(id.uuidString).\(ext)")
    try FileStore.createDirectory(dir)
    do {
      if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
      try FileManager.default.copyItem(at: url, to: destination)
    } catch {
      throw Unreadable()
    }
    return destination
  }
}

extension AttachmentCandidate {
  struct PhotoUnavailable: LocalizedError {
    var errorDescription: String? { "The photo couldn't be loaded (it may be in iCloud while offline)." }
  }

  /// Wraps a Photos picker item into an attachment candidate, deferring payload transfer
  /// and original byte preservation until pipeline ingestion.
  static func photo(_ item: PhotosPickerItem) -> AttachmentCandidate {
    let ext = item.supportedContentTypes.first?.preferredFilenameExtension
    return AttachmentCandidate(filename: nil) { dir, id in
      guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoUnavailable() }
      return try AttachmentStaging.write(data, into: dir, id: id, preferredExtension: ext)
    }
  }
}

/// View modifier managing system presentation sheets for Photo Library and Files document pickers,
/// coordinating selection limits, resource conversion, and asynchronous staging dispatch.
struct AttachmentImporters: ViewModifier {
  let model: ChatScreenModel
  @Binding var showPhotos: Bool
  @Binding var showFiles: Bool
  /// Ephemeral collection of selected photo items, reset following each import event to permit
  /// subsequent re-selection of identical assets.
  @State private var picked: [PhotosPickerItem] = []

  func body(content: Self.Content) -> some View {
    content
      .photosPicker(
        isPresented: $showPhotos, selection: $picked, maxSelectionCount: model.pickerLimit, selectionBehavior: .ordered,
        matching: .images, preferredItemEncoding: .current
      )
      .onChange(of: picked) { _, items in
        // Guard against secondary empty change emissions resulting from explicit state resets.
        guard !items.isEmpty else { return }
        picked = []
        let candidates = items.map(AttachmentCandidate.photo)
        Task { await model.attach(candidates, from: .photos) }
      }
      .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let candidates = urls.map(AttachmentCandidate.file)
        Task { await model.attach(candidates, from: .files) }
      }
  }
}
