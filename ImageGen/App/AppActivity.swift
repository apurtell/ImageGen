import Foundation

/// Whether the app is active and which chat is on screen (D§4.11). The main actor writes it from
/// `scenePhase` and the chat view; the generation actor reads it.
final class AppActivity: Sendable {
  private let state: Locked<(isActive: Bool, visibleConversationID: UUID?)>

  init(isActive: Bool = false, visibleConversationID: UUID? = nil) {
    state = Locked((isActive, visibleConversationID))
  }

  var isActive: Bool { state.value.isActive }
  var visibleConversationID: UUID? { state.value.visibleConversationID }

  func setActive(_ active: Bool) { state.withLock { $0.isActive = active } }

  /// `nil` clears it only if `id` is still the visible chat.
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
