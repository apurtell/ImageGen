import Foundation
import Observation

/// One instance, shared by both toolbars' Developer menus (D§3.10). It follows
/// `ActivityLog.changes()`, so whether Last Error has anything is known without opening a sheet.
@Observable @MainActor
final class DeveloperMenuModel {
  let log: ActivityLog
  private(set) var status = ActivityLogStatus(lastSequence: 0, lastActionID: nil, lastErrorID: nil)
  @ObservationIgnored private var task: Task<Void, Never>?

  init(log: ActivityLog) {
    self.log = log
    let stream = log.changes()
    task = Task { [weak self] in
      for await status in stream { self?.status = status }
    }
  }

  isolated deinit { task?.cancel() }

  var hasError: Bool { status.lastErrorID != nil }
  var lastActionID: ActionID? { status.lastActionID }
  var lastErrorID: ActionID? { status.lastErrorID }

  /// Clear Log… after its confirmation.
  func clearLog() async {
    await log.clear()
  }
}
