import UIKit

/// Copy (D§4.9): the original bytes under the original type only, so nothing is re-encoded.
/// `ImageExportModel` calls it, and it logs the Copy as one action (D§4.13). It is `@MainActor`, like
/// its caller and the UIKit pasteboard it writes. The file is read off the main thread (a 4K image is
/// about 10 MB), then written to the pasteboard on it.
@MainActor
struct PasteboardWriter {
  var pasteboard: UIPasteboard = .general
  let log: ActivityLog

  /// Returns whether the copy worked, so the caller can show a toast. `@discardableResult` lets a
  /// caller ignore it without a warning.
  @discardableResult
  func copy(_ item: ExportItem) async -> Bool {
    let action = log.begin("Copy", origin: .user, "image · \(item.logDescription)")
    let url = item.url
    do {
      // `Task.detached` has no actor, so the read runs off the main thread.
      let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
      pasteboard.setItems([[item.utType.identifier: data]])
      log.result(action, .success, "pasteboard written (1 item, \(item.utType.identifier))")
      return true
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
      return false
    }
  }
}
