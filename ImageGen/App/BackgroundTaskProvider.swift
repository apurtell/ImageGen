import Foundation
import UIKit

struct BackgroundTaskToken: Sendable, Hashable {
  let id: Int
}

/// Keeps the app running while a request is prepared, until its upload task exists (D§4.6).
protocol BackgroundTaskProviding: Sendable {
  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken
  func end(_ token: BackgroundTaskToken) async
}

/// `UIApplication` background-task assertions. The log is flushed before every end (plan §2.8
/// rule 9): capped at 1 s normally, and at 0.5 s in the expiry handler, after `onExpire` has
/// logged its result.
final class UIApplicationBackgroundTaskProvider: BackgroundTaskProviding {
  private let log: ActivityLog
  /// Assertions already ended: the expiry handler ends its own, and the owner's later `end` then
  /// does nothing (UIKit warns about ending one twice).
  private let ended = Locked<Set<Int>>([])

  init(log: ActivityLog) {
    self.log = log
  }

  @MainActor
  private final class Box {
    var identifier: UIBackgroundTaskIdentifier = .invalid
  }

  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken {
    let log = self.log
    let ended = self.ended
    let raw: Int = await MainActor.run {
      let box = Box()
      box.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
        onExpire()
        let id = box.identifier
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
    guard !ended.value.contains(token.id) else { return }
    await log.flush(timeout: .seconds(1))
    let ended = self.ended
    await MainActor.run { Self.endOnce(token.id, ended) }
  }

  @MainActor
  private static func endOnce(_ id: Int, _ ended: Locked<Set<Int>>) {
    guard ended.withLock({ $0.insert(id).inserted }) else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
  }

  /// Flushes the log under a short assertion of its own, when the scene goes to the background.
  func flushInBackground() async {
    let token = await begin(name: "log-flush") {}
    await end(token)
  }
}
