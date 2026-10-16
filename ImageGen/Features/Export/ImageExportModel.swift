import Observation
import SwiftUI
import UIKit

enum ImageExportAction: Sendable {
  case photos, files, share, copy
}

/// Save to Photos, Save to Files, Share and Copy for one screen (D§3.6, D§4.9). Each screen that
/// presents (the chat, the viewer) owns one, with `ImageExportPresenter` attached.
@Observable @MainActor
final class ImageExportModel {
  @ObservationIgnored let log: ActivityLog
  @ObservationIgnored private let photos: PhotoLibrarySaver
  @ObservationIgnored private let pasteboard: PasteboardWriter
  @ObservationIgnored private var exportLog: ExportLog { ExportLog(log: log) }

  private(set) var toast: String?
  /// Bumped on each successful save (haptic).
  private(set) var savedCount = 0
  var showPhotosDenied = false
  /// The Files exporter is shown while this is set.
  var fileExport: ExportItem?
  /// The share sheet is shown while this is set.
  var share: ShareTicket?

  @ObservationIgnored private var filesAction: ActionID?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(log: ActivityLog, photoLibrary: any PhotoLibraryAccess = SystemPhotoLibrary(), pasteboard: UIPasteboard = .general) {
    self.log = log
    photos = PhotoLibrarySaver(library: photoLibrary, log: log)
    self.pasteboard = PasteboardWriter(pasteboard: pasteboard, log: log)
  }

  func perform(_ action: ImageExportAction, _ item: ExportItem) {
    switch action {
    case .photos: Task { await saveToPhotos(item) }
    case .files: saveToFiles(item)
    case .share: beginShare(item)
    case .copy: copy(item)
    }
  }

  // MARK: Photos

  func saveToPhotos(_ item: ExportItem) async {
    switch await photos.save(item) {
    case .saved:
      savedCount += 1
      show("Saved to Photos")
    case .denied:
      showPhotosDenied = true
    case .failed(let reason):
      show("Couldn't save: \(reason)")
    }
  }

  // MARK: Files

  func saveToFiles(_ item: ExportItem) {
    filesAction = exportLog.beginFiles(item)
    fileExport = item
  }

  /// `.fileExporter`'s completion (a result) or cancellation (nil).
  func filesFinished(_ result: Result<URL, any Error>?) {
    var result = result
    if case .failure(let error as CocoaError) = result, error.code == .userCancelled { result = nil }
    fileExport = nil
    guard let action = filesAction else { return }
    filesAction = nil
    exportLog.endFiles(action, result)
    switch result {
    case .success:
      savedCount += 1
      show("Saved to Files")
    case .failure(let error): show("Couldn't save: \(error.localizedDescription)")
    case nil: break
    }
  }

  // MARK: Share

  /// The Share button's action: begins the Share before the sheet is presented.
  func beginShare(_ item: ExportItem) {
    share = exportLog.beginShare(item)
  }

  func shareFinished(_ ticket: ShareTicket, activityType: UIActivity.ActivityType?, completed: Bool, error: (any Error)?) {
    exportLog.endShare(ticket, activityType: activityType, completed: completed, error: error)
    if share === ticket { share = nil }
  }

  /// The sheet disappeared; ends the Share `cancelled` if its completion never came.
  func shareDisappeared(_ ticket: ShareTicket) {
    exportLog.endShareIfOpen(ticket)
    if share === ticket { share = nil }
  }

  // MARK: Copy

  func copy(_ item: ExportItem) {
    if pasteboard.copy(item) { show("Copied") }
  }

  // MARK: Toast

  func show(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }
}

/// Attaches the exporter, the share sheet, the Photos-denied alert, the toast and the haptic.
struct ImageExportPresenter: ViewModifier {
  @Bindable var model: ImageExportModel
  var toastAlignment: Alignment = .top
  var toastOffset: CGFloat = 8

  func body(content: Self.Content) -> some View {
    content
      .fileExporter(
        // SwiftUI clears isPresented before onCompletion arrives, so only onCompletion ends the action
        // (a cancel arrives there as CocoaError.userCancelled).
        isPresented: Binding(get: { model.fileExport != nil }, set: { if !$0 { model.fileExport = nil } }),
        document: model.fileExport.map { ImageFileDocument(file: $0.file) }, contentType: model.fileExport?.utType ?? .jpeg,
        defaultFilename: model.fileExport?.suggestedName,
        onCompletion: { model.filesFinished($0) }
      )
      .sheet(item: $model.share) { ticket in
        ActivityShareSheet(file: ticket.item.file) { type, completed, error in
          model.shareFinished(ticket, activityType: type, completed: completed, error: error)
        }
        .presentationDetents([.medium, .large])
        .ignoresSafeArea()
        .onDisappear { model.shareDisappeared(ticket) }
      }
      .alert("Photos access is off", isPresented: $model.showPhotosDenied) {
        Button("Open Settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Allow ImageGen to add photos in Settings to save images to your library.")
      }
      .toast(model.toast, alignment: toastAlignment, offset: toastOffset)
      .sensoryFeedback(.success, trigger: model.savedCount)
  }
}
