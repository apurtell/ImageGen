import Foundation

/// Whether the app is active and which chat is on screen (D§4.11). The main actor writes it from
/// `scenePhase` and the chat view; the generation actor reads it.
///
/// `NotificationPoster` and `AppDelegate` read it to decide whether a finished request needs a banner.
/// Concurrency: the reader (`GenerationService`, an actor) and the writer (the main actor) are in
/// different concurrency domains, and the reader must not wait for the main thread. So the state is a
/// plain value behind a lock (`Locked`; see the primer, *Locks*), not main-actor state. Each read and
/// each write is one short locked step, which makes the class `Sendable`.
final class AppActivity: Sendable {
  private let state: Locked<(isActive: Bool, visibleConversationID: UUID?)>

  init(isActive: Bool = false, visibleConversationID: UUID? = nil) {
    state = Locked((isActive, visibleConversationID))
  }

  var isActive: Bool { state.value.isActive }
  var visibleConversationID: UUID? { state.value.visibleConversationID }

  func setActive(_ active: Bool) { state.withLock { $0.isActive = active } }

  /// `nil` clears it only if `id` is still the visible chat.
  ///
  /// The chat view calls this with `leaving:` when it disappears. When the user goes from chat A to
  /// chat B, B can appear before A disappears. The check keeps A's late "leaving" call from clearing B.
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
