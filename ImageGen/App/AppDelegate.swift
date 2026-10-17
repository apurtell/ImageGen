import UIKit
import UserNotifications

/// Bridges system level UIKit lifecycle events to the application environment.
///
/// Handles lifecycle integration points not directly represented in SwiftUI: post-launch service initialization,
/// background URLSession wake events (`handleEventsForBackgroundURLSession`), and UserNotifications delivery.
/// Adapts untyped system completion handlers into typed, isolated coordinator routines managed by `AppEnvironment`.
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

  /// Handles background URLSession wake events, capturing the system completion callback within
  /// `BackgroundEventsRelay` until all payload downloads are processed and persisted.
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard !AppEnvironment.isTestHost else {
      completionHandler()
      return
    }
    // Encapsulates the unannotated completion handler for safe dispatch onto the main thread.
    nonisolated(unsafe) let handler = completionHandler
    AppEnvironment.shared.relay.store(identifier: identifier) { handler() }
  }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
  // Employs completion handler based delegate signatures to guarantee that system notification callbacks
  // execute strictly on the main thread, avoiding background thread snapshot assertions during UI activation.

  /// Determines foreground notification presentation behavior, suppressing banners when the notification
  /// targets the conversation currently displayed in the foreground.
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

  /// Routes user activation of a local notification to `NotificationRouter` for deep-link navigation.
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
