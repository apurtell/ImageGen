import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Copies a file chosen in the Files importer into `Staging/` under its security scope (D§4.8 step 1).
enum FileImport {
  struct Unreadable: LocalizedError {
    var errorDescription: String? { "The file couldn't be read." }
  }

  /// A file from another app's storage is readable only between the start and stop of its security
  /// scope. `defer` stops the access on every exit, including a throw. It runs in a detached task
  /// (see `importAndPrepare`), so a large copy doesn't block the main thread.
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

  /// A Photos picker item, loaded as its original bytes (`.current` encoding keeps HEIC).
  /// The load can take long (an iCloud download); it happens in the item's task, not here.
  static func photo(_ item: PhotosPickerItem) -> AttachmentCandidate {
    let ext = item.supportedContentTypes.first?.preferredFilenameExtension
    return AttachmentCandidate(filename: nil) { dir, id in
      guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoUnavailable() }
      return try AttachmentStaging.write(data, into: dir, id: id, preferredExtension: ext)
    }
  }
}

/// The + menu's pickers (D§3.5): Photo Library (ordered multi-select, limit `max(1, 14 - tray)`)
/// and Files (no count limit; extras over the cap are dropped with a toast).
///
/// A `ViewModifier` packages the two picker presentations so `ComposerInputRow` can attach them in
/// one line. `@Binding` connects `showPhotos` and `showFiles` to the input row's `@State`.
struct AttachmentImporters: ViewModifier {
  let model: ChatScreenModel
  @Binding var showPhotos: Bool
  @Binding var showFiles: Bool
  /// The picker's selection. It is cleared after each pick, so the next pick starts empty and
  /// `.onChange` fires again even for the same photos.
  @State private var picked: [PhotosPickerItem] = []

  func body(content: Self.Content) -> some View {
    content
      .photosPicker(
        isPresented: $showPhotos, selection: $picked, maxSelectionCount: model.pickerLimit, selectionBehavior: .ordered,
        matching: .images, preferredItemEncoding: .current
      )
      .onChange(of: picked) { _, items in
        // Clearing `picked` fires `.onChange` again with an empty array; the guard ignores it.
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
