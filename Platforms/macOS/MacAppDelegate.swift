import AppKit
import UserNotifications

/// Handles macOS application lifecycle and notification events.
///
/// Forwards launch and notification events to `AppEnvironment`. Background URLSession wake
/// events do not exist on macOS, so the app handles completion events directly.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !AppEnvironment.isTestHost else { return }
    UNUserNotificationCenter.current().delegate = self
    AppEnvironment.shared.didFinishLaunching(applicationState: NSApp.isActive ? .active : .inactive)
  }
}

extension MacAppDelegate: UNUserNotificationCenterDelegate {
  /// Suppresses completion banners if the user is already viewing the target chat in the foreground.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let id = (notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    nonisolated(unsafe) let done = completionHandler
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        let activity = AppEnvironment.shared.activity
        done(activity.isActive && id != nil && activity.visibleConversationID == id ? [] : [.banner, .sound])
      }
    }
  }

  /// Routes notification taps to `NotificationRouter` to navigate to the chat.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = (response.notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    nonisolated(unsafe) let done = completionHandler
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if let id { AppEnvironment.shared.router.open(id) }
        done()
      }
    }
  }
}
