import Foundation

/// Thread safe tracker for application foreground activity and visible conversation context.
///
/// Consulted by `NotificationPoster` and `AppDelegate` to determine notification presentation policy:
/// suppressing completion alerts when the target conversation is actively viewed in the foreground.
/// Concurrency: bridges `@MainActor` UI view lifecycles with the `GenerationService` actor domain
/// using lightweight mutual exclusion (`Locked`), ensuring lock free nonblocking reads across concurrency boundaries.
final class AppActivity: Sendable {
  private let state: Locked<(isActive: Bool, visibleConversationID: UUID?)>

  init(isActive: Bool = false, visibleConversationID: UUID? = nil) {
    state = Locked((isActive, visibleConversationID))
  }

  var isActive: Bool { state.value.isActive }
  var visibleConversationID: UUID? { state.value.visibleConversationID }

  func setActive(_ active: Bool) { state.withLock { $0.isActive = active } }

  /// Updates visible conversation context. When `leaving` is specified, clears the identifier
  /// only if it matches the current value, preventing out-of-order disappearance transitions
  /// from clearing newly presented conversations.
  func setVisible(_ id: UUID?, leaving: UUID? = nil) {
    state.withLock { s in
      if let leaving {
        if s.visibleConversationID == leaving { s.visibleConversationID = nil }
      } else {
        s.visibleConversationID = id
      }
    }
  }
}
