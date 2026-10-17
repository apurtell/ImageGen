import Observation
import SwiftUI
import UIKit

/// Image export operations supported by context menus and modal image viewer toolbars.
enum ImageExportAction: Sendable {
  case photos, files, share, copy
}

/// Presentation model orchestrating asset export lifecycles across photo library persistence,
/// document file exports, system activity sheets, and pasteboard operations.
///
/// Coordinates activity logging and lifecycle closure guarantees across asynchronous and UI-driven
/// export workflows, ensuring all begun export actions resolve to deterministic completion results.
@Observable @MainActor
final class ImageExportModel {
  @ObservationIgnored let log: ActivityLog
  @ObservationIgnored private let photos: PhotoLibrarySaver
  @ObservationIgnored private let pasteboard: PasteboardWriter
  @ObservationIgnored private var exportLog: ExportLog { ExportLog(log: log) }

  /// Ephemeral confirmation message displayed within transient toast overlays.
  private(set) var toast: String?
  /// Monotonic counter incremented upon successful persistence to trigger tactile sensory feedback.
  private(set) var savedCount = 0
  var showPhotosDenied = false
  /// Item currently presented to the system document file exporter.
  var fileExport: ExportItem?
  /// Active share ticket driving modal activity sheet presentation.
  var share: ShareTicket?

  /// In-flight document export action identifier awaiting system callback resolution.
  @ObservationIgnored private var filesAction: ActionID?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(log: ActivityLog, photoLibrary: any PhotoLibraryAccess = SystemPhotoLibrary(), pasteboard: UIPasteboard = .general) {
    self.log = log
    photos = PhotoLibrarySaver(library: photoLibrary, log: log)
    self.pasteboard = PasteboardWriter(pasteboard: pasteboard, log: log)
  }

  /// Dispatches the requested export operation for the target asset.
  func perform(_ action: ImageExportAction, _ item: ExportItem) {
    switch action {
    // Dispatch asynchronous photo library export independently of the invoking UI lifecycle.
    case .photos: Task { await saveToPhotos(item) }
    case .files: saveToFiles(item)
    case .share: beginShare(item)
    case .copy: Task { await self.copy(item) }
    }
  }

  /// Persists the asset to the user's Photos library, logging authorization and write outcomes.
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

  /// Initiates file exporter presentation, cancelling any prior unresolved export actions.
  func saveToFiles(_ item: ExportItem) {
    // Supersede any uncompleted file export actions prior to initiating a new export lifecycle.
    closeOpenActions(reason: "superseded by another Save to Files")
    filesAction = exportLog.beginFiles(item)
    fileExport = item
  }

  /// Resolves the document export action upon receiving the system file exporter completion callback.
  func filesFinished(_ result: Result<URL, any Error>?) {
    var result = result
    // Treat user cancellation as a clean cancellation rather than an unexpected failure.
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

  /// Initiates an activity sheet share action, closing any previously active share operation.
  func beginShare(_ item: ExportItem) {
    if let open = share { exportLog.endShareIfOpen(open) }
    share = exportLog.beginShare(item)
  }

  /// Concludes any open export operations that terminated without receiving explicit system callbacks.
  func closeOpenActions(reason: String = "the screen closed") {
    if let action = filesAction {
      filesAction = nil
      fileExport = nil
      log.result(action, .cancelled, "\(reason)")
    }
    if let ticket = share {
      exportLog.endShareIfOpen(ticket)
      share = nil
    }
  }

  /// Processes completion of the system activity sheet matching the specified share ticket.
  func shareFinished(_ ticket: ShareTicket, activityType: UIActivity.ActivityType?, completed: Bool, error: (any Error)?) {
    exportLog.endShare(ticket, activityType: activityType, completed: completed, error: error)
    if share === ticket { share = nil }
  }

  /// Handles activity sheet dismissal, cancelling active share tickets if no explicit completion occurred.
  func shareDisappeared(_ ticket: ShareTicket) {
    exportLog.endShareIfOpen(ticket)
    if share === ticket { share = nil }
  }

  /// Copies the asset payload to the system pasteboard.
  func copy(_ item: ExportItem) async {
    if await pasteboard.copy(item) { show("Copied") }
  }

  /// Displays a transient informational toast message for a standard display duration.
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

/// View modifier managing system presentation bindings for file exporters, activity sheets,
/// authorization alerts, toast overlays, and haptic feedback.
struct ImageExportPresenter: ViewModifier {
  @Bindable var model: ImageExportModel
  var toastAlignment: Alignment = .top
  var toastOffset: CGFloat = 8

  func body(content: Self.Content) -> some View {
    content
      .fileExporter(
        // Defer action completion until explicit onCompletion callback resolution.
        isPresented: Binding(get: { model.fileExport != nil }, set: { if !$0 { model.fileExport = nil } }),
        document: model.fileExport.map { ImageFileDocument(file: $0.file) }, contentType: model.fileExport?.utType ?? .jpeg,
        defaultFilename: model.fileExport?.suggestedName,
        onCompletion: { model.filesFinished($0) }
      )
      // Correlate activity sheet lifecycle callbacks with the associated share ticket.
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
      // Ensure any pending export operations resolve to cancelled states upon view dismissal.
      .onDisappear { model.closeOpenActions() }
  }
}
