import Foundation
import UserNotifications

/// The system permission request, behind a protocol so that tests can supply a fake answer.
protocol NotificationAuthorizing: Sendable {
  /// Asks for alert and sound; returns whether it was granted and the authorization status now.
  func request() async -> (granted: Bool, status: String)
}

/// The production authorizer: `UNUserNotificationCenter`. It shows the system alert the first time.
struct UserNotificationAuthorizer: NotificationAuthorizing {
  func request() async -> (granted: Bool, status: String) {
    let center = UNUserNotificationCenter.current()
    let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false  // An error counts as not granted.
    let status = await center.notificationSettings().authorizationStatus
    return (granted, Self.name(status))
  }

  /// The status as a short word, for the log and the Settings sheet.
  static func name(_ s: UNAuthorizationStatus) -> String {
    switch s {
    case .authorized: "authorized"
    case .denied: "denied"
    case .notDetermined: "notDetermined"
    case .provisional: "provisional"
    case .ephemeral: "ephemeral"
    // `@unknown default` handles a case that a later iOS version adds.
    @unknown default: "unknown"
    }
  }
}

/// Asks for notification permission once, on the first send (D§4.11), and logs it as its own
/// system action, so Last Action still shows the Send.
///
/// The chat screen calls `requestOnFirstSend()` on each send; only the first call asks. When the user
/// denies, the app works normally and Settings shows the status. `@MainActor`, so two sends cannot run
/// the check at the same time.
@MainActor
final class NotificationPermission {
  static let askedKey = "notifications.askedOnFirstSend"

  private let authorizer: any NotificationAuthorizing
  private let defaults: UserDefaults
  private let log: ActivityLog
  /// DEBUG `-SkipNotificationPrompt 1`: never ask, so unattended UI tests are not blocked.
  private let skip: Bool

  init(authorizer: any NotificationAuthorizing, defaults: UserDefaults, log: ActivityLog, skip: Bool = false) {
    self.authorizer = authorizer
    self.defaults = defaults
    self.log = log
    self.skip = skip
  }

  var hasAsked: Bool { defaults.bool(forKey: Self.askedKey) }

  func requestOnFirstSend() async {
    guard !skip, !hasAsked else { return }
    // The flag is set before the `await`: a second send while the system alert is on screen runs
    // while this call waits, and it must find the flag already set.
    defaults.set(true, forKey: Self.askedKey)
    let action = log.begin("Notification permission", origin: .system, "asked on the first send · options alert, sound")
    let (granted, status) = await authorizer.request()
    log.result(action, .success, "\(granted ? "granted" : "denied") · authorization \(status)")
  }
}
