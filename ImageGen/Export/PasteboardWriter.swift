import UIKit

/// Copy (D§4.9): the original bytes under the original type only, so nothing is re-encoded.
@MainActor
struct PasteboardWriter {
  var pasteboard: UIPasteboard = .general
  let log: ActivityLog

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
