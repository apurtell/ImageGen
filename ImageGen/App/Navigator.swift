import Foundation
import Observation

/// App navigation (D§3.1): the chat path, the Settings sheet, and onboarding.
///
/// `RootView` binds its `NavigationStack` and its Settings sheet to these properties, so a change here
/// pushes, pops or presents a screen (see the primer, *SwiftUI: the user interface*). Any screen model
/// can navigate by changing the navigator; it does not need a reference to a view. `@Observable` makes
/// SwiftUI redraw the views that read a property when it changes. `@MainActor`: all navigation happens
/// on the main thread.
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
    // The page path is set before the sheet opens, so the sheet appears already on that page.
    settingsPath = page.map { [$0] } ?? []
    showSettings = true
  }

  /// Opens one chat directly on top of the chat list, replacing any chat that is open.
  func open(_ conversationID: UUID) {
    path = [conversationID]
  }

  /// New Chat from a chat screen replaces it, so Back returns to the chat list (D§3.4).
  func replaceTop(with conversationID: UUID) {
    if path.isEmpty { path = [conversationID] } else { path[path.count - 1] = conversationID }
  }
}

/// A page that can be pushed inside the Settings sheet.
enum SettingsPage: Hashable {
  case models
}
