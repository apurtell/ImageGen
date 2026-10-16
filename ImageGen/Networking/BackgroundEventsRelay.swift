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
  /// Sessions whose events finished before UIKit handed over the handler (the session is made at
  /// launch, so its events can arrive first): a `store` soon after completes at once. Events can
  /// also finish with no handler to follow (queued events delivered when the user opens the app),
  /// so the note is honoured only for `earlyWindow`; an older one would end a later wake's handler
  /// before that wake's completions were handled.
  private var finishedEarly: [String: (handled: Int, at: ContinuousClock.Instant)] = [:]
  static let earlyWindow: Duration = .seconds(10)
  private let now: @MainActor () -> ContinuousClock.Instant

  init(log: ActivityLog, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
    self.log = log
    self.now = now
  }

  func store(identifier: String, handler: @escaping @MainActor () -> Void) {
    let action = log.begin("Background events", origin: .system, "session \(identifier)")
    if let previous = pending[identifier] {
      log.result(previous.action, .success, "superseded by a newer wake")
      previous.handler()
    }
    pending[identifier] = Pending(handler: handler, action: action, storedAt: now())
    if let early = finishedEarly.removeValue(forKey: identifier), now() - early.at <= Self.earlyWindow {
      Task { await self.callAndClear(identifier: identifier, completionsHandled: early.handled, early: true) }
    }
  }

  var hasPending: Bool { !pending.isEmpty }

  func callAndClear(identifier: String, completionsHandled: Int, early: Bool = false) async {
    guard let p = pending.removeValue(forKey: identifier) else {
      // The early path found the handler already completed by the real end of events: nothing to note.
      if !early { finishedEarly[identifier] = (completionsHandled, now()) }
      return
    }
    let elapsed = now() - p.storedAt
    log.result(
      p.action, .success,
      "in \(Format.seconds(elapsed)) · \(completionsHandled) completion\(completionsHandled == 1 ? "" : "s") handled before the system handler\(early ? " (events finished before the handler arrived)" : "")")
    await log.flush(timeout: .seconds(1))
    p.handler()
  }
}
