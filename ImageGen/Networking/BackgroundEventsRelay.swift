import Foundation

/// Holds the system's background-session completion handlers (D§4.6 "Waking in the background").
/// Each wake is a Background events action, ended once `GenerationService` has handled every
/// earlier completion; the log is flushed before the handler runs, because the OS may suspend the
/// app as soon as it does (plan §2.8 rule 9).
@MainActor
final class BackgroundEventsRelay {
  private struct Pending {
    let handler: @MainActor () -> Void
    let action: ActionID
    let storedAt: ContinuousClock.Instant
  }

  private let log: ActivityLog
  private var pending: [String: Pending] = [:]

  init(log: ActivityLog) {
    self.log = log
  }

  func store(identifier: String, handler: @escaping @MainActor () -> Void) {
    let action = log.begin("Background events", origin: .system, "session \(identifier)")
    if let previous = pending[identifier] {
      log.result(previous.action, .success, "superseded by a newer wake")
      previous.handler()
    }
    pending[identifier] = Pending(handler: handler, action: action, storedAt: .now)
  }

  var hasPending: Bool { !pending.isEmpty }

  func callAndClear(identifier: String, completionsHandled: Int) async {
    guard let p = pending.removeValue(forKey: identifier) else { return }
    let elapsed = ContinuousClock.now - p.storedAt
    log.result(
      p.action, .success,
      "in \(Format.seconds(elapsed)) · \(completionsHandled) completion\(completionsHandled == 1 ? "" : "s") handled before the system handler")
    await log.flush(timeout: .seconds(1))
    p.handler()
  }
}
