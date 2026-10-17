import Foundation
import UserNotifications

/// The content of one local notification for a finished request.
struct ReplyNotification: Sendable, Equatable {
  let conversationID: UUID
  let title: String
  let body: String
}

/// What `post` did, so `GenerationService` can log it as a step.
enum NotificationOutcome: Sendable, Equatable {
  case posted(body: String)
  case suppressed(reason: String)

  var logText: String {
    switch self {
    case .posted(let body): "notification posted: \(body)"
    case .suppressed(let reason): "notification not posted: \(reason)"
    }
  }
}

/// The seam between `GenerationService` and the notification system, so tests can record posts.
protocol NotificationPosting: Sendable {
  func post(_ notification: ReplyNotification) async -> NotificationOutcome
}

/// Posts a local notification for a finished request, unless the app is active with that chat on
/// screen, or the Settings toggle is off (D§4.11).
///
/// `GenerationService` (an actor) calls `post` when a request reaches a terminal state. So the poster
/// must not depend on the main actor: it reads `AppActivity` (a locked value) and reads the Settings
/// toggle straight from `UserDefaults` through `isEnabled`. The struct holds only `Sendable` values and
/// `@Sendable` closures, so it is `Sendable` itself.
struct NotificationPoster: NotificationPosting {
  let activity: AppActivity
  let isEnabled: @Sendable () -> Bool
  let deliver: @Sendable (ReplyNotification) async -> Void

  func post(_ n: ReplyNotification) async -> NotificationOutcome {
    guard isEnabled() else { return .suppressed(reason: "turned off in Settings") }
    if activity.isActive && activity.visibleConversationID == n.conversationID {
      return .suppressed(reason: "chat is on screen")
    }
    await deliver(n)
    return .posted(body: n.body)
  }

  /// The production poster: `UNUserNotificationCenter`, grouped by chat.
  static func userNotifications(activity: AppActivity, settingsSuite: String?) -> NotificationPoster {
    NotificationPoster(
      activity: activity,
      // A new `UserDefaults` for each call: the closure keeps only the suite name, which is `Sendable`.
      isEnabled: {
        let ud = settingsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return AppSettings.readNotifyOnBackgroundCompletion(ud)
      },
      deliver: { n in
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = .default
        // `threadIdentifier` groups notifications by chat; `userInfo` carries the chat for a tap
        // (`AppDelegate` reads it).
        content.threadIdentifier = n.conversationID.uuidString
        content.userInfo = ["conversationID": n.conversationID.uuidString]
        // `trigger: nil` delivers it now.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)  // A failed post loses only the banner; the reply is saved.
      })
  }

  /// The body for a finished request (D§4.11).
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
