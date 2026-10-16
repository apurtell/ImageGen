import Foundation
import UIKit

/// One Share: begun when the button is tapped, ended at most once (D§4.13).
final class ShareTicket: Sendable, Identifiable {
  let id = UUID()
  let action: ActionID
  let item: ExportItem
  fileprivate let ended = Locked(false)

  fileprivate init(action: ActionID, item: ExportItem) {
    self.action = action
    self.item = item
  }

  var hasEnded: Bool { ended.value }
}

/// Logging for Save to Files and Share, whose presentation and completion happen in views
/// (`.fileExporter`, `ActivityShareSheet`). Save to Photos and Copy log in their own types.
struct ExportLog: Sendable {
  let log: ActivityLog

  func beginFiles(_ item: ExportItem) -> ActionID {
    log.begin("Save to Files", origin: .user, "\(item.logDescription) · \(item.suggestedName)")
  }

  func endFiles(_ action: ActionID, _ result: Result<URL, any Error>?) {
    switch result {
    case .success(let url): log.result(action, .success, "saved \(url.lastPathComponent)")
    case .failure(let error): log.result(action, .failed, "\(error.localizedDescription)")
    case nil: log.result(action, .cancelled, "dismissed")
    }
  }

  func beginShare(_ item: ExportItem) -> ShareTicket {
    ShareTicket(action: log.begin("Share", origin: .user, "\(item.logDescription)"), item: item)
  }

  /// From the share sheet's completion handler; a second call writes nothing.
  func endShare(_ ticket: ShareTicket, activityType: UIActivity.ActivityType?, completed: Bool, error: (any Error)?) {
    let first = ticket.ended.withLock { ended in
      defer { ended = true }
      return !ended
    }
    guard first else { return }
    if let error {
      log.result(ticket.action, .failed, "\(error.localizedDescription)")
    } else if completed {
      log.result(ticket.action, .success, "via \(activityType?.rawValue ?? "unknown activity")")
    } else {
      log.result(ticket.action, .cancelled, "dismissed")
    }
  }

  /// The sheet went away without calling its completion.
  func endShareIfOpen(_ ticket: ShareTicket) {
    endShare(ticket, activityType: nil, completed: false, error: nil)
  }
}
