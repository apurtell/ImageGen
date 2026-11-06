import Foundation
import UIKit

/// Wraps `UIApplication.beginBackgroundTask` to keep the app running while preparing requests,
/// flushing the activity log before the task ends or expires.
///
/// Thread safety: methods can be called from any actor and dispatch to the main actor as required
/// by UIApplication. A thread-safe set (`Locked<Set<Int>>`) ensures tasks are ended exactly once,
/// even if normal completion and system expiration happen at the same time.
final class SystemBackgroundTaskProvider: BackgroundTaskProviding {
  private let log: ActivityLog
  private let ended = Locked<Set<Int>>([])

  init(log: ActivityLog) {
    self.log = log
  }

  /// Holds the system task identifier so the expiration handler can read it after creation.
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

  /// Ends the system background task once.
  @MainActor
  private static func endOnce(_ id: Int, _ ended: Locked<Set<Int>>) {
    guard ended.withLock({ $0.insert(id).inserted }) else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
  }
}
