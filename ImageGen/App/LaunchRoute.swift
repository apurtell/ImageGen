import Foundation

/// Where the app opens after launch (DEBUG `-Scene`, through `DebugHooks.prepareLaunch`).
/// `RootView.apply(_:)` turns a route into `Navigator` changes. In Release builds no route is made.
enum LaunchRoute: Equatable, Sendable {
  case chatList
  case chat(UUID)
  case settings
  case settingsModels
  case viewer(UUID)
  case onboarding
}
