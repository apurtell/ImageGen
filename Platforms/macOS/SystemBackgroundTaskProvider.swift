import Foundation

/// Keeps the process active using `ProcessInfo.beginActivity` while a generation request is prepared.
final class SystemBackgroundTaskProvider: BackgroundTaskProviding {
  private let log: ActivityLog
  /// Holds the opaque token returned by ProcessInfo.beginActivity.
  private struct Activity: @unchecked Sendable {
    let token: any NSObjectProtocol
  }

  private let activities = Locked<[Int: Activity]>([:])
  private let nextID = Locked<Int>(0)
  private let liveActivity = Locked<Activity?>(nil)

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

  func liveRequestsChanged(count: Int) {
    liveActivity.withLock { live in
      if count > 0, live == nil {
        live = Activity(token: ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "image request in flight"))
      } else if count == 0, let activity = live {
        ProcessInfo.processInfo.endActivity(activity.token)
        live = nil
      }
    }
  }
}
