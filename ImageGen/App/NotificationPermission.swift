import Foundation
import UserNotifications

/// Abstraction for system level notification authorization requests, allowing deterministic mock substitution.
protocol NotificationAuthorizing: Sendable {
  /// Requests notification authorization options (.alert, .sound) and queries active authorization status.
  func request() async -> (granted: Bool, status: String)
}

/// Production notification authorization adapter delegating to `UNUserNotificationCenter`.
struct UserNotificationAuthorizer: NotificationAuthorizing {
  func request() async -> (granted: Bool, status: String) {
    let center = UNUserNotificationCenter.current()
    let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    let status = await center.notificationSettings().authorizationStatus
    return (granted, Self.name(status))
  }

  /// Canonical string representation of authorization status for telemetry and settings presentation.
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

/// Orchestrates user notification permission acquisition on first generation dispatch.
///
/// Gated to run exactly once across the application lifecycle. Gating state is persisted to `UserDefaults`.
/// Operates on `@MainActor` to prevent race conditions during rapid consecutive dispatches,
/// committing the acquisition flag prior to asynchronous suspension.
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
    // Optimistically record that the prompt was presented prior to awaiting the system dialog,
    // ensuring concurrent dispatches do not duplicate the request.
    defaults.set(true, forKey: Self.askedKey)
    let action = log.begin("Notification permission", origin: .system, "asked on the first send · options alert, sound")
    let (granted, status) = await authorizer.request()
    log.result(action, .success, "\(granted ? "granted" : "denied") · authorization \(status)")
  }
}
