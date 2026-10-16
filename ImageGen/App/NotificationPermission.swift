import Foundation
import UserNotifications

protocol NotificationAuthorizing: Sendable {
  /// Asks for alert and sound; returns whether it was granted and the authorization status now.
  func request() async -> (granted: Bool, status: String)
}

struct UserNotificationAuthorizer: NotificationAuthorizing {
  func request() async -> (granted: Bool, status: String) {
    let center = UNUserNotificationCenter.current()
    let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    let status = await center.notificationSettings().authorizationStatus
    return (granted, Self.name(status))
  }

  static func name(_ s: UNAuthorizationStatus) -> String {
    switch s {
    case .authorized: "authorized"
    case .denied: "denied"
    case .notDetermined: "notDetermined"
    case .provisional: "provisional"
    case .ephemeral: "ephemeral"
    @unknown default: "unknown"
    }
  }
}

/// Asks for notification permission once, on the first send (D§4.11), and logs it as its own
/// system action, so Last Action still shows the Send.
@MainActor
final class NotificationPermission {
  static let askedKey = "notifications.askedOnFirstSend"

  private let authorizer: any NotificationAuthorizing
  private let defaults: UserDefaults
  private let log: ActivityLog
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
    defaults.set(true, forKey: Self.askedKey)
    let action = log.begin("Notification permission", origin: .system, "asked on the first send · options alert, sound")
    let (granted, status) = await authorizer.request()
    log.result(action, .success, "\(granted ? "granted" : "denied") · authorization \(status)")
  }
}
