import SwiftUI

/// Primary navigation layout presentation styles for adaptive iOS environments.
enum NavigationLayout: Sendable, Equatable {
  /// Single-column hierarchical navigation stack where detail views push over the conversation list.
  case stack
  /// Multi-column split view displaying the conversation list in a persistent sidebar alongside the detail view.
  case split

  /// Determines the appropriate layout presentation based on device idiom and horizontal size class.
  /// Split view presentation is restricted to iPad devices with a regular horizontal size class; compact widths
  /// and iPhone form factors always utilize the hierarchical stack.
  static func choose(isPad: Bool, isRegularWidth: Bool) -> NavigationLayout {
    isPad && isRegularWidth ? .split : .stack
  }
}

extension EnvironmentValues {
  /// Active navigation presentation layout propagated through the SwiftUI environment hierarchy.
  @Entry var navigationLayout: NavigationLayout = .stack
}
