import Foundation
import Observation

/// App navigation (D§3.1): the chat path, the Settings sheet, and onboarding.
@Observable @MainActor
final class Navigator {
  /// Conversation IDs pushed on the chat list.
  var path: [UUID] = []
  var showSettings = false
  /// Pages pushed inside the Settings sheet when it opens (the 404 card's Open Models).
  var settingsPath: [SettingsPage] = []
  /// No key is stored (or `-Scene onboarding`), so onboarding replaces the chat list.
  var needsOnboarding = false

  func openSettings(_ page: SettingsPage? = nil) {
    settingsPath = page.map { [$0] } ?? []
    showSettings = true
  }

  func open(_ conversationID: UUID) {
    path = [conversationID]
  }

  /// New Chat from a chat screen replaces it, so Back returns to the chat list (D§3.4).
  func replaceTop(with conversationID: UUID) {
    if path.isEmpty { path = [conversationID] } else { path[path.count - 1] = conversationID }
  }
}

enum SettingsPage: Hashable {
  case models
}
