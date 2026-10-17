import Foundation
import UIKit

/// An opaque handle for one background-task assertion; `end` takes it back.
struct BackgroundTaskToken: Sendable, Hashable {
  let id: Int
}

/// Keeps the app running while a request is prepared, until its upload task exists (D§4.6).
///
/// When the app goes to the background, iOS suspends it after a few seconds. A background-task
/// assertion asks for more time; shortly before that time ends, iOS calls an expiry handler (see the
/// primer, *iOS application lifecycle*). `GenerationService` takes one for each send, regenerate and
/// retry, and `AppEnvironment` takes one to flush the log. The protocol lets tests use a recording fake
/// that can fire expiry.
protocol BackgroundTaskProviding: Sendable {
  /// `onExpire` runs when iOS is about to end the extra time. The assertion is then ended for the
  /// caller; a later `end` with the same token does nothing.
  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken
  func end(_ token: BackgroundTaskToken) async
}

/// `UIApplication` background-task assertions. The log is flushed before every end (plan §2.8
/// rule 9): capped at 1 s normally, and at 0.5 s in the expiry handler, after `onExpire` has
/// logged its result.
///
/// Concurrency: callers are on any actor (mostly `GenerationService`), but `UIApplication` must be used
/// on the main thread. So `begin` and `end` are `async` and hop to the main actor with `MainActor.run`.
/// The `ended` set is behind a lock (`Locked`), because `end` reads it before that hop.
final class UIApplicationBackgroundTaskProvider: BackgroundTaskProviding {
  private let log: ActivityLog
  /// Assertions already ended: the expiry handler ends its own, and the owner's later `end` then
  /// does nothing (UIKit warns about ending one twice).
  private let ended = Locked<Set<Int>>([])

  init(log: ActivityLog) {
    self.log = log
  }

  /// The expiry handler needs the identifier that `beginBackgroundTask` returns, but the handler is
  /// made before that call returns. The box lets the handler read the identifier later. It is
  /// `@MainActor` because UIKit makes the call and runs the handler on the main thread.
  @MainActor
  private final class Box {
    var identifier: UIBackgroundTaskIdentifier = .invalid
  }

  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken {
    // Copied into locals so that the closures below capture these values and not `self`.
    let log = self.log
    let ended = self.ended
    let raw: Int = await MainActor.run {
      let box = Box()
      box.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
        // The owner logs its Result first, then the log is flushed, then the assertion ends.
        onExpire()
        let id = box.identifier
        // The flush is `async` and the expiry handler is not, so the flush and the end run in a task.
        Task { @MainActor in
          await log.flush(timeout: .milliseconds(500))
          Self.endOnce(id.rawValue, ended)
        }
      }
      return box.identifier.rawValue
    }
    return BackgroundTaskToken(id: raw)
  }

  func end(_ token: BackgroundTaskToken) async {
    // A fast exit when expiry already ended it. This check is not enough by itself: expiry can still
    // fire during the flush below. `endOnce` makes the final decision.
    guard !ended.value.contains(token.id) else { return }
    await log.flush(timeout: .seconds(1))
    let ended = self.ended
    await MainActor.run { Self.endOnce(token.id, ended) }
  }

  /// Ends the assertion unless it is already ended. The insert into `ended` is the test and the mark in
  /// one locked step, so exactly one of the expiry handler and `end` calls `endBackgroundTask`.
  @MainActor
  private static func endOnce(_ id: Int, _ ended: Locked<Set<Int>>) {
    guard ended.withLock({ $0.insert(id).inserted }) else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
  }

  /// Flushes the log under a short assertion of its own, when the scene goes to the background.
  /// (`end` does the flush.)
  func flushInBackground() async {
    let token = await begin(name: "log-flush") {}
    await end(token)
  }
}
