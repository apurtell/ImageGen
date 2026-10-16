import Foundation
import Observation

/// Where a tapped notification should take the user (D§4.11). M5's navigation observes it.
@Observable @MainActor
final class NotificationRouter {
  /// The chat to open; the chat list clears it once it has pushed the chat.
  var pendingConversationID: UUID?

  func open(_ conversationID: UUID) {
    pendingConversationID = conversationID
  }
}
