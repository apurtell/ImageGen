import Foundation

/// Holds the system's background-session completion handlers (D§4.6 "Waking in the background").
///
/// When a background transfer finishes while the app is suspended or not running, iOS starts the app
/// in the background and gives `AppDelegate` a completion handler (see the primer, *iOS application
/// lifecycle*). The app must call that handler after it has handled every result of the wake. The
/// `AppDelegate` gives the handler to this relay with `store`. `GenerationService` calls `callAndClear`
/// when it reaches the transport's `.finishedEvents` event. Because the service handles the event stream
/// in order, every earlier completion is already parsed and saved at that point.
///
/// Each wake is a Background events action, ended once `GenerationService` has handled every earlier
/// completion. The log is flushed before the handler runs, because the OS may suspend the app as soon as
/// it does (plan §2.8 rule 9).
///
/// Concurrency: the class is `@MainActor`, so every member runs on the main thread, one call at a time,
/// and the dictionaries need no lock. UIKit calls the delegate on the main thread and expects the
/// handler to be called there too. See the primer, *Actors*.
@MainActor
final class BackgroundEventsRelay {
  /// One stored system handler and the open Background events action that it ends.
  private struct Pending {
    let handler: @MainActor () -> Void
    let action: ActionID
    let storedAt: ContinuousClock.Instant
  }

  private let log: ActivityLog
  /// Keyed by the background session identifier. At most one handler is pending for each session.
  private var pending: [String: Pending] = [:]
  /// Sessions whose events finished before UIKit handed over the handler (the session is made at
  /// launch, so its events can arrive first): a `store` soon after completes at once. Events can
  /// also finish with no handler to follow (queued events delivered when the user opens the app),
  /// so the note is honored only for `earlyWindow`; an older one would end a later wake's handler
  /// before that wake's completions were handled.
  private var finishedEarly: [String: (handled: Int, at: ContinuousClock.Instant)] = [:]
  static let earlyWindow: Duration = .seconds(10)
  /// The clock, injected so that tests can move time past `earlyWindow`.
  private let now: @MainActor () -> ContinuousClock.Instant

  init(log: ActivityLog, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
    self.log = log
    self.now = now
  }

  /// Called by `AppDelegate` with the handler that UIKit gave it. Begins one Background events action.
  func store(identifier: String, handler: @escaping @MainActor () -> Void) {
    let action = log.begin("Background events", origin: .system, "session \(identifier)")
    // A new wake for the same session replaces the old handler. The old one is called now, so that
    // UIKit never holds a handler that the app forgot, and its action gets its one Result.
    if let previous = pending[identifier] {
      log.result(previous.action, .success, "superseded by a newer wake")
      previous.handler()
    }
    pending[identifier] = Pending(handler: handler, action: action, storedAt: now())
    // The events for this wake already finished: complete the handler at once. The call goes through a
    // `Task` because `callAndClear` is `async` (it awaits the log flush) and `store` is synchronous.
    // `Task {}` keeps the main actor, so the call still runs on the main thread.
    if let early = finishedEarly.removeValue(forKey: identifier), now() - early.at <= Self.earlyWindow {
      Task { await self.callAndClear(identifier: identifier, completionsHandled: early.handled, early: true) }
    }
  }

  var hasPending: Bool { !pending.isEmpty }

  /// Ends the session's Background events action, flushes the log and calls the system handler.
  /// `GenerationService` calls it when it handles `.finishedEvents`; `store` calls it with `early: true`.
  /// With no pending handler, it records the finish in `finishedEarly` for a `store` that comes later.
  func callAndClear(identifier: String, completionsHandled: Int, early: Bool = false) async {
    // The handler is removed before the `await` below. A second call for the same session, which can
    // run while this one waits for the flush, then finds nothing and cannot call the handler twice.
    guard let p = pending.removeValue(forKey: identifier) else {
      // The early path found the handler already completed by the real end of events: nothing to note.
      if !early { finishedEarly[identifier] = (completionsHandled, now()) }
      return
    }
    let elapsed = now() - p.storedAt
    log.result(
      p.action, .success,
      "in \(Format.seconds(elapsed)) · \(completionsHandled) completion\(completionsHandled == 1 ? "" : "s") handled before the system handler\(early ? " (events finished before the handler arrived)" : "")")
    // The flush is capped at 1 s, so a slow disk cannot hold the handler past the background time.
    await log.flush(timeout: .seconds(1))
    p.handler()
  }
}
