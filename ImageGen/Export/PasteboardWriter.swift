import UIKit

/// Handles system clipboard export operations, copying raw asset data directly under its native uniform type
/// identifier to prevent fidelity loss from transcoding.
@MainActor
struct PasteboardWriter {
  var pasteboard: UIPasteboard = .general
  let log: ActivityLog

  /// Writes the asset data to the system pasteboard asynchronously, emitting action telemetry and returning success status.
  @discardableResult
  func copy(_ item: ExportItem) async -> Bool {
    let action = log.begin("Copy", origin: .user, "image · \(item.logDescription)")
    let url = item.url
    do {
      // Read raw file bytes off the main thread prior to staging onto the system pasteboard.
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
