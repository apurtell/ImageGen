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

  init(log: ActivityLog) {
    self.log = log
  }

  @MainActor
  private final class Box {
    var identifier: UIBackgroundTaskIdentifier = .invalid
  }

  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken {
    let log = self.log
    let raw: Int = await MainActor.run {
      let box = Box()
      box.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
        onExpire()
        let id = box.identifier
        Task { @MainActor in
          await log.flush(timeout: .milliseconds(500))
          UIApplication.shared.endBackgroundTask(id)
        }
      }
      return box.identifier.rawValue
    }
    return BackgroundTaskToken(id: raw)
  }

  func end(_ token: BackgroundTaskToken) async {
    await log.flush(timeout: .seconds(1))
    await MainActor.run {
      UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.id))
    }
  }

  /// Flushes the log under a short assertion of its own, when the scene goes to the background.
  func flushInBackground() async {
    let token = await begin(name: "log-flush") {}
    await end(token)
  }
}
