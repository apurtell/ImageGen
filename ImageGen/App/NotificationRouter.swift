import Foundation
import Observation

/// Coordinates deep link routing triggered by notification activations.
///
/// Buffers pending conversation target identifiers received from `AppDelegate` until the presentation
/// hierarchy (`RootView`) is mounted and ready to process navigation stack mutations.
@Observable @MainActor
final class NotificationRouter {
  /// Buffered conversation identifier targeted for presentation.
  /// Consumed and cleared upon receipt by `RootView`.
  var pendingConversationID: UUID?

  func open(_ conversationID: UUID) {
    pendingConversationID = conversationID
  }
}
