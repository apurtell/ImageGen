import Foundation
import Observation

/// Centralized presentation and navigation coordinator.
///
/// Encapsulates programmatic routing across `RootView` presentation hierarchies: navigation stack paths,
/// modal settings sheets, and modal onboarding workflows. View models mutate navigator state on `@MainActor`,
/// triggering declarative SwiftUI view updates without direct view couplings.
@Observable @MainActor
final class Navigator {
  /// Navigation stack history represented by conversation identifiers.
  var path: [UUID] = []
  var showSettings = false
  /// Sub-destinations pushed onto the internal settings navigation stack.
  var settingsPath: [SettingsPage] = []
  /// Flag presenting the onboarding modal when valid API credentials are absent.
  var needsOnboarding = false

  func openSettings(_ page: SettingsPage? = nil) {
    settingsPath = page.map { [$0] } ?? []
    showSettings = true
  }

  /// Replaces the active navigation stack with a single conversation destination.
  func open(_ conversationID: UUID) {
    path = [conversationID]
  }

  /// Replaces the top-most view on the stack, ensuring back-navigation returns directly to the root chat list.
  func replaceTop(with conversationID: UUID) {
    if path.isEmpty { path = [conversationID] } else { path[path.count - 1] = conversationID }
  }
}

/// Identifiers for nested navigation pages within the settings hierarchy.
enum SettingsPage: Hashable {
  case models
}
