import Foundation
import UIKit

/// Thread safe tracking token representing an active share presentation session.
///
/// Ensures exactly once terminal logging across multiple potential completion triggers, including
/// sheet completion callbacks, dismissal lifecycle events, or subsequent export operations.
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

/// Structured telemetry coordinator for UI-driven export flows, providing action tracking and disposition
/// reporting for file export sheets and system activity controllers.
struct ExportLog: Sendable {
  let log: ActivityLog

  func beginFiles(_ item: ExportItem) -> ActionID {
    log.begin("Save to Files", origin: .user, "\(item.logDescription) · \(item.suggestedName)")
  }

  /// Records the terminal outcome of a file export operation, treating nil results as user cancellation.
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

  /// Records the completion disposition of an active share session, ensuring atomic first-completion handling.
  func endShare(_ ticket: ShareTicket, activityType: UIActivity.ActivityType?, completed: Bool, error: (any Error)?) {
    // Atomically test-and-set the completion flag to guarantee exactly-once terminal recording.
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

  /// Concludes an active share session as dismissed if no explicit completion handler was previously triggered.
  func endShareIfOpen(_ ticket: ShareTicket) {
    endShare(ticket, activityType: nil, completed: false, error: nil)
  }
}
