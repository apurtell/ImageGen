import SwiftUI

/// Root presentation container arbitrating primary navigation stacks, modals, and route dispatch.
///
/// Binds `Navigator` state to the platform's primary navigation and settings presentation.
/// Coordinates initial presentation frame signaling to `AppEnvironment` for filesystem cleanup qualification,
/// listens for incoming notification deep links, and applies programmatic launch routing.
struct RootView: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    let navigator = env.navigator
    Group {
      if navigator.needsOnboarding {
        OnboardingView(
          model: OnboardingModel(
            keyStore: env.keyStore, availability: env.availability, registry: env.registry, log: env.log)
        ) {
          navigator.needsOnboarding = false
        }
        .onboardingLayout()
      } else {
        PrimaryNavigation()
      }
    }
    .settingsPresentation()
    .onChange(of: env.router.pendingConversationID, initial: true) { _, id in
      guard let id else { return }
      env.router.pendingConversationID = nil
      Task { await openFromNotification(id) }
    }
    .task {
      env.firstFrameAppeared()
      if let route = await DebugHooks.prepareLaunch(env) { apply(route) }
    }
  }

  /// Verifies conversation existence before transitioning navigation stack to the target identifier.
  private func openFromNotification(_ id: UUID) async {
    guard (try? await env.store.conversationTitle(id)) != nil else { return }
    env.navigator.open(id)
  }

  /// Dispatches programmatic launch routing to the navigation coordinator.
  private func apply(_ route: LaunchRoute) {
    let navigator = env.navigator
    switch route {
    case .chatList:
      navigator.path = []
    case .chat(let id):
      navigator.path = [id]
    case .settings:
      navigator.openSettings()
    case .settingsModels:
      navigator.openSettings(.models)
    case .viewer(let id):
      navigator.path = [id]
    case .onboarding:
      navigator.needsOnboarding = true
    }
  }
}
