import UIKit

/// Copy (D§4.9): the original bytes under the original type only, so nothing is re-encoded.
/// `ImageExportModel` calls it, and it logs the Copy as one action (D§4.13). It is `@MainActor`, like
/// its caller and the UIKit pasteboard it writes. It reads the whole file on the main thread, which
/// is short for one image.
@MainActor
struct PasteboardWriter {
  var pasteboard: UIPasteboard = .general
  let log: ActivityLog

  /// Returns whether the copy worked, so the caller can show a toast. `@discardableResult` lets a
  /// caller ignore it without a warning.
  @discardableResult
  func copy(_ item: ExportItem) -> Bool {
    let action = log.begin("Copy", origin: .user, "image · \(item.logDescription)")
    do {
      let data = try Data(contentsOf: item.url)
      pasteboard.setItems([[item.utType.identifier: data]])
      log.result(action, .success, "pasteboard written (1 item, \(item.utType.identifier))")
      return true
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
      return false
    }
  }
}
