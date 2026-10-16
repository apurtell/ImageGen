import SwiftUI

/// Onboarding or the chat list, the Settings sheet, the notification router, and launch routes.
struct RootView: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    @Bindable var navigator = env.navigator
    Group {
      if navigator.needsOnboarding {
        OnboardingView(
          model: OnboardingModel(
            keyStore: env.keyStore, availability: env.availability, registry: env.registry, log: env.log)
        ) {
          navigator.needsOnboarding = false
        }
      } else {
        NavigationStack(path: $navigator.path) {
          ChatListView()
            .navigationDestination(for: UUID.self) { id in
              ChatView(conversationID: id, services: env.chatServices())
                .id(id)
            }
        }
      }
    }
    .sheet(isPresented: $navigator.showSettings) {
      SettingsView(keyModel: env.apiKeySectionModel(), model: env.settingsModel())
    }
    .onChange(of: env.router.pendingConversationID) { _, id in
      guard let id else { return }
      navigator.open(id)
      env.router.pendingConversationID = nil
    }
    .task {
      env.firstFrameAppeared()
      if let route = await DebugHooks.prepareLaunch(env) { apply(route) }
    }
  }

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
