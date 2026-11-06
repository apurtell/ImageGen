import Foundation

/// Keeps the process active using `ProcessInfo.beginActivity` while a generation request is prepared.
///
/// Prevents App Nap and sudden termination until the request payload has been passed to the
/// background URLSession daemon. macOS assertions do not expire, so `onExpire` is never called.
final class SystemBackgroundTaskProvider: BackgroundTaskProviding {
  private let log: ActivityLog
  /// Holds the opaque token returned by ProcessInfo.beginActivity.
  private struct Activity: @unchecked Sendable {
    let token: any NSObjectProtocol
  }

  private let activities = Locked<[Int: Activity]>([:])
  private let nextID = Locked<Int>(0)

  init(log: ActivityLog) {
    self.log = log
  }

  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken {
    let id = nextID.withLock { value in
      value += 1
      return value
    }
    let activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: name)
    activities.withLock { $0[id] = Activity(token: activity) }
    return BackgroundTaskToken(id: id)
  }

  func end(_ token: BackgroundTaskToken) async {
    guard activities.value[token.id] != nil else { return }
    await log.flush(timeout: .seconds(1))
    if let activity = activities.withLock({ $0.removeValue(forKey: token.id) }) {
      ProcessInfo.processInfo.endActivity(activity.token)
    }
  }
}
