import Observation
import SwiftUI
import UIKit

/// The four export actions that the context menus and the viewer's toolbar offer (D§3.6).
enum ImageExportAction: Sendable {
  case photos, files, share, copy
}

/// Save to Photos, Save to Files, Share and Copy for one screen (D§3.6, D§4.9). Each screen that
/// presents (the chat, the viewer) owns one, with `ImageExportPresenter` attached.
///
/// The model is the screen-level half of the export layer. It calls the `Export/` types
/// (`PhotoLibrarySaver`, `PasteboardWriter`, `ExportLog`) and holds the state that
/// `ImageExportPresenter` turns into a file exporter, a share sheet, an alert, a toast and a haptic.
///
/// The logging rule: each export is one action with exactly one Result. Photos and Copy finish
/// inside one call, so their types log them. Save to Files and Share begin here, but they end in a
/// system screen whose completion can come late, or never (the screen closes, or another export
/// starts). So the model remembers the open action and closes it on every path: on completion,
/// when superseded, and when the screen goes away (`closeOpenActions`).
///
/// Concurrency: `@MainActor`, so all state changes happen on the main thread. Only Save to Photos
/// awaits (for the permission prompt and the library write); the rest is synchronous.
@Observable @MainActor
final class ImageExportModel {
  @ObservationIgnored let log: ActivityLog
  @ObservationIgnored private let photos: PhotoLibrarySaver
  @ObservationIgnored private let pasteboard: PasteboardWriter
  @ObservationIgnored private var exportLog: ExportLog { ExportLog(log: log) }

  /// The toast text, or nil. `show(_:)` clears it after 2 seconds.
  private(set) var toast: String?
  /// Bumped on each successful save (haptic).
  private(set) var savedCount = 0
  var showPhotosDenied = false
  /// The Files exporter is shown while this is set.
  var fileExport: ExportItem?
  /// The share sheet is shown while this is set.
  var share: ShareTicket?

  /// The Save to Files action that has begun and has no Result yet. At most one is open.
  @ObservationIgnored private var filesAction: ActionID?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(log: ActivityLog, photoLibrary: any PhotoLibraryAccess = SystemPhotoLibrary(), pasteboard: UIPasteboard = .general) {
    self.log = log
    photos = PhotoLibrarySaver(library: photoLibrary, log: log)
    self.pasteboard = PasteboardWriter(pasteboard: pasteboard, log: log)
  }

  /// The entry point for menus and toolbars, which cannot `await`.
  func perform(_ action: ImageExportAction, _ item: ExportItem) {
    switch action {
    // An unstructured task that inherits the main actor. Nothing keeps a handle: a save that has
    // started finishes even if the screen closes, and its toast then has no effect.
    case .photos: Task { await saveToPhotos(item) }
    case .files: saveToFiles(item)
    case .share: beginShare(item)
    case .copy: Task { await self.copy(item) }
    }
  }

  // MARK: Photos

  /// `PhotoLibrarySaver` writes this action's Begin and its Result.
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

  /// Begins the Save to Files action, then sets `fileExport`, which shows the system exporter.
  func saveToFiles(_ item: ExportItem) {
    // An earlier export whose completion never came gets its Result now, before the new Begin.
    closeOpenActions(reason: "superseded by another Save to Files")
    filesAction = exportLog.beginFiles(item)
    fileExport = item
  }

  /// `.fileExporter`'s completion (a result) or cancellation (nil).
  /// The only place where a completed Save to Files gets its Result.
  func filesFinished(_ result: Result<URL, any Error>?) {
    var result = result
    // A cancel arrives as an error; it is logged as `cancelled`, not `failed`, and shows no toast.
    if case .failure(let error as CocoaError) = result, error.code == .userCancelled { result = nil }
    fileExport = nil
    // nil when `closeOpenActions` already wrote this action's Result: write nothing a second time.
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
  /// Setting `share` presents the sheet. The ticket carries the action, and it ends at most once.
  func beginShare(_ item: ExportItem) {
    // A Share still open is superseded: it ends `cancelled` before the new one begins.
    if let open = share { exportLog.endShareIfOpen(open) }
    share = exportLog.beginShare(item)
  }

  /// Ends a Save to Files or Share whose completion never came (its screen went away, or another
  /// started), so each still gets exactly one Result.
  /// Called by the presenter's `.onDisappear`, and by `saveToFiles` before a new Begin.
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

  /// The share sheet's completion handler. The ticket, not `share`, says which Share ended: a late
  /// completion of an old sheet must not end, or clear, a newer Share.
  func shareFinished(_ ticket: ShareTicket, activityType: UIActivity.ActivityType?, completed: Bool, error: (any Error)?) {
    exportLog.endShare(ticket, activityType: activityType, completed: completed, error: error)
    // `===` compares object identity: clear `share` only if it is still this ticket.
    if share === ticket { share = nil }
  }

  /// The sheet disappeared; ends the Share `cancelled` if its completion never came.
  /// When the completion did come, the ticket has already ended, and this writes nothing.
  func shareDisappeared(_ ticket: ShareTicket) {
    exportLog.endShareIfOpen(ticket)
    if share === ticket { share = nil }
  }

  // MARK: Copy

  /// `PasteboardWriter` logs the Copy and returns whether it succeeded.
  func copy(_ item: ExportItem) async {
    if await pasteboard.copy(item) { show("Copied") }
  }

  // MARK: Toast

  /// Shows a toast for 2 seconds. A newer toast cancels the older one's timer, so the older timer
  /// cannot hide the newer text early.
  func show(_ text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))  // try?: a cancelled sleep is handled by the check below.
      // Cancellation only sets a flag; this check is what stops a replaced timer.
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }
}

/// Attaches the exporter, the share sheet, the Photos-denied alert, the toast and the haptic.
///
/// The view half of `ImageExportModel`: each presentation is bound to one of the model's
/// properties, and each system callback goes back to the model, which writes the log. It also
/// closes any open export when the screen goes away.
struct ImageExportPresenter: ViewModifier {
  /// `@Bindable` gives `$model.share` and `$model.showPhotosDenied`: two-way bindings to the model.
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
      // The sheet's closures capture this `ticket`, so each callback names the Share it belongs to.
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
      // The screen went away with an export still open: give it its Result now, so none is left
      // without one.
      .onDisappear { model.closeOpenActions() }
  }
}
