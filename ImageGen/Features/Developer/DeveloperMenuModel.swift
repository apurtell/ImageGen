import Foundation
import Observation

/// One instance, shared by both toolbars' Developer menus (D§3.10). It follows
/// `ActivityLog.changes()`, so whether Last Error has anything is known without opening a sheet.
///
/// `AppEnvironment` creates it and provides it to the views with `.environment(...)`. It is
/// `@Observable` (SwiftUI redraws the menus when `status` changes) and `@MainActor` (all of its state
/// is read and written on the main thread). One unstructured task reads the status stream for the
/// life of the object; it is the only writer of `status`.
@Observable @MainActor
final class DeveloperMenuModel {
  let log: ActivityLog
  /// The latest status from the log. It starts empty and is replaced by the first value from the
  /// stream, which arrives at once (the stream sends the current status first).
  private(set) var status = ActivityLogStatus(lastSequence: 0, lastActionID: nil, lastErrorID: nil)
  /// `@ObservationIgnored`: the task handle is bookkeeping, not state that a view reads.
  @ObservationIgnored private var task: Task<Void, Never>?

  init(log: ActivityLog) {
    self.log = log
    let stream = log.changes()
    // `Task {}` here inherits the main actor, so the loop body can write `status` directly.
    // `[weak self]`: the task does not keep the model alive. The stream is an `AsyncStream` that
    // keeps only the newest value, so a slow reader skips to the current status (see the primer,
    // *AsyncStream*).
    task = Task { [weak self] in
      for await status in stream { self?.status = status }
    }
  }

  /// `isolated deinit` runs the clean-up on the main actor, where `task` lives. Cancelling ends the
  /// `for await` loop.
  isolated deinit { task?.cancel() }

  var hasError: Bool { status.lastErrorID != nil }
  var lastActionID: ActionID? { status.lastActionID }
  var lastErrorID: ActionID? { status.lastErrorID }

  /// Clear Log… after its confirmation. The log keeps the Begins of actions that still run and
  /// writes a "Log cleared" action; the new status then arrives through the stream.
  func clearLog() async {
    await log.clear()
  }
}
