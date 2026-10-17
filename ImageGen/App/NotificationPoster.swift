import Foundation
import UserNotifications

/// Value payload for local reply notifications.
struct ReplyNotification: Sendable, Equatable {
  let conversationID: UUID
  let title: String
  let body: String
}

/// Terminal delivery outcome captured for diagnostic activity logs.
enum NotificationOutcome: Sendable, Equatable {
  case posted(body: String)
  case suppressed(reason: String)
  /// System notification dispatch error (conversation persistence proceeds unhindered).
  case failed(reason: String)

  var logText: String {
    switch self {
    case .posted(let body): "notification posted: \(body)"
    case .suppressed(let reason): "notification not posted: \(reason)"
    case .failed(let reason): "notification not posted: \(reason)"
    }
  }
}

/// Interface for dispatching completion notifications, facilitating automated test inspection.
protocol NotificationPosting: Sendable {
  func post(_ notification: ReplyNotification) async -> NotificationOutcome
}

/// Dispatches local completion alerts according to user configuration and foreground presentation context.
///
/// Invoked by `GenerationService` upon request completion. Evaluates suppression rules:
/// 1. Disables dispatch when user notification preferences are toggled off.
/// 2. Suppresses alerts when the target conversation is actively visible in the foreground.
/// Concurrency: completely non-isolated and thread-safe, reading settings directly from `UserDefaults`
/// and visible state from `AppActivity` without hopping to `@MainActor`.
struct NotificationPoster: NotificationPosting {
  let activity: AppActivity
  let isEnabled: @Sendable () -> Bool
  let deliver: @Sendable (ReplyNotification) async throws -> Void

  func post(_ n: ReplyNotification) async -> NotificationOutcome {
    guard isEnabled() else { return .suppressed(reason: "turned off in Settings") }
    if activity.isActive && activity.visibleConversationID == n.conversationID {
      return .suppressed(reason: "chat is on screen")
    }
    do {
      try await deliver(n)
    } catch {
      return .failed(reason: error.localizedDescription)
    }
    return .posted(body: n.body)
  }

  /// Production factory utilizing `UNUserNotificationCenter`, grouping notification threads by conversation.
  static func userNotifications(activity: AppActivity, settingsSuite: String?) -> NotificationPoster {
    NotificationPoster(
      activity: activity,
      isEnabled: {
        let ud = settingsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return AppSettings.readNotifyOnBackgroundCompletion(ud)
      },
      deliver: { n in
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        content.threadIdentifier = n.conversationID.uuidString
        content.userInfo = ["conversationID": n.conversationID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
      })
  }

  /// Formats notification body text based on terminal request state and multimodal content.
  static func body(state: RequestState, imageCount: Int, text: String?, refusalReason: String?, failure: String?) -> String {
    switch state {
    case .succeeded:
      if imageCount > 0 { return "Image ready" }
      let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? "Reply ready" : String(t.prefix(80))
    case .refused:
      return "Request refused: \(refusalReason ?? "unknown")"
    default:
      return "Generation failed: \(failure ?? state.rawValue)"
    }
  }
}
