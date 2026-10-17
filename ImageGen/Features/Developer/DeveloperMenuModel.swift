import Foundation
import Observation

/// Presentation model driving developer diagnostics menus across application toolbars.
///
/// Subscribes to the continuous activity log status stream to maintain up-to-date awareness of recent
/// actions and error events without requiring on-demand log traversal.
@Observable @MainActor
final class DeveloperMenuModel {
  let log: ActivityLog
  /// Latest activity log status snapshot reflecting active sequence positions and error identifiers.
  private(set) var status = ActivityLogStatus(lastSequence: 0, lastActionID: nil, lastErrorID: nil)
  /// Long-lived observation task receiving activity log status updates.
  @ObservationIgnored private var task: Task<Void, Never>?

  init(log: ActivityLog) {
    self.log = log
    let stream = log.changes()
    // Observe the asynchronous status stream on the main actor to apply status updates reactively.
    task = Task { [weak self] in
      for await status in stream { self?.status = status }
    }
  }

  /// Actor isolated deinitializer ensuring background status subscription tasks are cancelled.
  isolated deinit { task?.cancel() }

  var hasError: Bool { status.lastErrorID != nil }
  var lastActionID: ActionID? { status.lastActionID }
  var lastErrorID: ActionID? { status.lastErrorID }

  /// Clears persisted activity log entries while preserving lifecycle markers for currently active actions.
  func clearLog() async {
    await log.clear()
  }
}
