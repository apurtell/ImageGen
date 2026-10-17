import Foundation

/// Coordinates system background session completion handlers across background execution cycles.
///
/// When URLSession background transfers terminate while the application is suspended or terminated,
/// iOS launches the application in the background and delivers a completion closure to `AppDelegate`.
/// The host application is contractually required to invoke this closure once all pending transfer
/// outcomes have been processed and persisted to storage.
///
/// Lifecycle Coordination:
/// - `AppDelegate` delegates incoming completion closures to this relay via `store(identifier:handler:)`.
/// - `GenerationService` signals transfer reconciliation by invoking `callAndClear(identifier:completionsHandled:)`
///   upon consuming the transport's terminal `.finishedEvents` event stream marker.
/// - Activity logs are flushed with a strict timeout prior to invoking the system closure to guarantee
///   diagnostic persistence before the operating system suspends or terminates the process.
/// - Operates on `@MainActor` to serialize access without explicit synchronization locks, matching UIKit conventions.
@MainActor
final class BackgroundEventsRelay {
  /// Encapsulates a retained system completion handler and its correlated telemetry span.
  private struct Pending {
    let handler: @MainActor () -> Void
    let action: ActionID
    let storedAt: ContinuousClock.Instant
  }

  private let log: ActivityLog
  /// Active system completion handlers indexed by URLSession background identifier.
  private var pending: [String: Pending] = [:]
  /// Tracks sessions whose transfer events concluded prior to UIKit delegate invocation.
  /// Bounded by `earlyWindow` to avoid prematurely completing handlers belonging to subsequent wakes.
  private var finishedEarly: [String: (handled: Int, at: ContinuousClock.Instant)] = [:]
  static let earlyWindow: Duration = .seconds(10)
  /// Time provider abstraction enabling deterministic validation of reconciliation timeouts.
  private let now: @MainActor () -> ContinuousClock.Instant

  init(log: ActivityLog, now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
    self.log = log
    self.now = now
  }

  /// Registers a system completion handler delivered by UIKit for a background session wake cycle.
  func store(identifier: String, handler: @escaping @MainActor () -> Void) {
    let action = log.begin("Background events", origin: .system, "session \(identifier)")
    // If a prior handler is active for the same session, supersede and invoke it to prevent system leaks.
    if let previous = pending[identifier] {
      log.result(previous.action, .success, "superseded by a newer wake")
      previous.handler()
    }
    pending[identifier] = Pending(handler: handler, action: action, storedAt: now())
    // Immediately discharge if corresponding transfer events finished prior to handler registration.
    if let early = finishedEarly.removeValue(forKey: identifier), now() - early.at <= Self.earlyWindow {
      Task { await self.callAndClear(identifier: identifier, completionsHandled: early.handled, early: true) }
    }
  }

  var hasPending: Bool { !pending.isEmpty }

  /// Concludes background event processing, flushes diagnostic logs, and signals the operating system.
  /// If invoked before the system handler has been registered, records the completion within the early reconciliation window.
  func callAndClear(identifier: String, completionsHandled: Int, early: Bool = false) async {
    // Atomically claim the pending handler before suspension to guarantee single-invocation semantics across suspension points.
    guard let p = pending.removeValue(forKey: identifier) else {
      if !early { finishedEarly[identifier] = (completionsHandled, now()) }
      return
    }
    let elapsed = now() - p.storedAt
    log.result(
      p.action, .success,
      "in \(Format.seconds(elapsed)) · \(completionsHandled) completion\(completionsHandled == 1 ? "" : "s") handled before the system handler\(early ? " (events finished before the handler arrived)" : "")")
    // Bound diagnostic flush duration to protect process lifetime constraints before system suspension.
    await log.flush(timeout: .seconds(1))
    p.handler()
  }
}
