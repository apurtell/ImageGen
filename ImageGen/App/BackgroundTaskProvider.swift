import Foundation
import UIKit

/// Opaque token representing an active background execution assertion.
struct BackgroundTaskToken: Sendable, Hashable {
  let id: Int
}

/// Interface for managing transient background execution assertions.
///
/// Prevents premature process suspension while request payloads are prepared, downscaled,
/// and handed off to the system background URLSession daemon. Supports injection of test doubles
/// to simulate system expiration timeouts deterministically.
protocol BackgroundTaskProviding: Sendable {
  /// Initiates an execution assertion, invoking `onExpire` if system limits are reached prior to explicit termination.
  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken
  func end(_ token: BackgroundTaskToken) async
}

/// Manages `UIApplication` background execution assertions, coordinating diagnostic log flushing
/// prior to assertion invalidation.
///
/// Thread safety: methods are callable across arbitrary actor domains and marshal execution
/// onto `@MainActor` as required by `UIApplication`. A thread-safe registry (`Locked<Set<Int>>`)
/// guarantees idempotent, single-invalidation semantics across concurrent normal completions and system expirations.
final class UIApplicationBackgroundTaskProvider: BackgroundTaskProviding {
  private let log: ActivityLog
  private let ended = Locked<Set<Int>>([])

  init(log: ActivityLog) {
    self.log = log
  }

  /// Mutable container bridging delayed identifier initialization to early expiration callbacks.
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

  /// Atomically invalidates the system background task identifier exactly once.
  @MainActor
  private static func endOnce(_ id: Int, _ ended: Locked<Set<Int>>) {
    guard ended.withLock({ $0.insert(id).inserted }) else { return }
    UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
  }
}
