import Foundation
import Observation

/// Where a tapped notification should take the user (D§4.11). M5's navigation observes it.
///
/// `AppDelegate` writes the chat ID when the user taps a notification. `RootView` observes the property
/// and opens the chat. The value waits here when the tap launches the app, until `RootView` exists.
/// `@Observable @MainActor`: SwiftUI sees each change, and all access is on the main thread.
@Observable @MainActor
final class NotificationRouter {
  /// The chat to open. `RootView` clears it as soon as it reads it, then opens the chat.
  var pendingConversationID: UUID?

  func open(_ conversationID: UUID) {
    pendingConversationID = conversationID
  }
}
