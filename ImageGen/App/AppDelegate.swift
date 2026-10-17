import UIKit
import UserNotifications

/// The UIKit application delegate: the place where iOS reports process-level events to the app.
///
/// A SwiftUI app has no delegate by default; `ImageGenApp` attaches this one with
/// `@UIApplicationDelegateAdaptor`. It handles three things that SwiftUI does not expose: the end of
/// launch (which starts the Reconciler through `AppEnvironment`), the background-session wake
/// (D§4.6, "Waking in the background"), and notification presentation and taps (D§4.11). It holds no
/// state; each method forwards to an object in `AppEnvironment.shared`.
///
/// Concurrency: UIKit calls the `UIApplicationDelegate` methods on the main thread. The notification
/// methods are `nonisolated` and `async`, so they can run off the main thread; they hop to the main
/// actor with `MainActor.run` before they touch `AppEnvironment`. See the primer, *Actors*.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // Under the unit-test host the app stays inert: no environment, no session (plan §2.2).
    guard !AppEnvironment.isTestHost else { return true }
    // The notification delegate must be set before launch ends, or a tap that launched the app is lost.
    UNUserNotificationCenter.current().delegate = self
    // The first use of `AppEnvironment.shared` creates it, if `ImageGenApp.init` has not already.
    AppEnvironment.shared.didFinishLaunching(applicationState: application.applicationState)
    return true
  }

  /// iOS started or woke the app because the background session has results. The handler must be
  /// called once the app has handled them; `BackgroundEventsRelay` does that.
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
    // `nonisolated(unsafe)`: UIKit's handler type is not marked `Sendable`, so the compiler cannot prove
    // that it is safe to keep in the relay's main-actor closure. It is safe because it is only called on
    // the main thread (see the primer, *Sendable*).
    nonisolated(unsafe) let handler = completionHandler
    AppEnvironment.shared.relay.store(identifier: identifier) { handler() }
  }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
  /// A banner for chats that aren't on screen (D§4.11).
  ///
  /// iOS asks this only while the app is in front. The rule matches `NotificationPoster`: no banner for
  /// the chat that is on screen while the app is active.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let id = (notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    return await MainActor.run {
      let activity = AppEnvironment.shared.activity
      return activity.isActive && id != nil && activity.visibleConversationID == id ? [] : [.banner, .sound]
    }
  }

  /// The user tapped a notification: hand its chat to `NotificationRouter`, which `RootView` observes.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let id = (response.notification.request.content.userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
    else { return }
    await MainActor.run { AppEnvironment.shared.router.open(id) }
  }
}
