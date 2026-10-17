import Foundation

/// Navigation destination targeted during initial application launch coordination.
/// Applied by `RootView` to mutate `Navigator` state across deep-link, automated test, or scene restoration paths.
enum LaunchRoute: Equatable, Sendable {
  case chatList
  case chat(UUID)
  case settings
  case settingsModels
  case viewer(UUID)
  case onboarding
}
