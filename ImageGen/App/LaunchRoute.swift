import Foundation

/// Where the app opens after launch (DEBUG `-Scene`, through `DebugHooks.prepareLaunch`).
enum LaunchRoute: Equatable, Sendable {
  case chatList
  case chat(UUID)
  case settings
  case settingsModels
  case viewer(UUID)
  case onboarding
}
