import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    guard !AppEnvironment.isTestHost else { return true }
    UNUserNotificationCenter.current().delegate = self
    AppEnvironment.shared.didFinishLaunching(applicationState: application.applicationState)
    return true
  }

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard !AppEnvironment.isTestHost else {
      completionHandler()
      return
    }
    // UIKit calls this on the main thread and expects the handler called there; the relay does.
    nonisolated(unsafe) let handler = completionHandler
    AppEnvironment.shared.relay.store(identifier: identifier) { handler() }
  }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
  /// A banner for chats that aren't on screen (D§4.11).
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let id = (notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    return await MainActor.run {
      let activity = AppEnvironment.shared.activity
      return activity.isActive && id != nil && activity.visibleConversationID == id ? [] : [.banner, .sound]
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let id = (response.notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    else { return }
    await MainActor.run { AppEnvironment.shared.router.open(id) }
  }
}
