import SwiftUI

/// Onboarding or the chat list, the Settings sheet, the notification router, and launch routes.
///
/// The top of the view tree. It reads `AppEnvironment` from the environment and shows either
/// onboarding (no key) or the chat list in a `NavigationStack`. `Navigator` drives what is pushed or
/// presented. It also tells the environment when the first frame is up, which lets the Janitor run.
/// Views run on the main actor. See the primer, *SwiftUI: the user interface*.
struct RootView: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    // `@Bindable` on a local: gives two-way bindings (`$navigator.path`) to the `@Observable` navigator.
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
              // `.id(id)` gives each chat its own view identity, so a replaced chat (New Chat) gets a
              // new screen and model, not the old ones with a new ID.
              ChatView(conversationID: id, services: env.chatServices())
                .id(id)
            }
        }
      }
    }
    .sheet(isPresented: $navigator.showSettings) {
      SettingsView(keyModel: env.apiKeySectionModel(), model: env.settingsModel())
    }
    // `initial: true`: a tap that cold-launches the app sets the chat before this view exists, and
    // a plain onChange treats that first value as the starting point, not a change.
    .onChange(of: env.router.pendingConversationID, initial: true) { _, id in
      guard let id else { return }
      // Cleared first, so the same tap is not handled again.
      env.router.pendingConversationID = nil
      // The existence check awaits the store, so it runs in a task; `Task {}` keeps the main actor.
      Task { await openFromNotification(id) }
    }
    // `.task` runs when the view appears. The first frame is then up.
    .task {
      env.firstFrameAppeared()
      if let route = await DebugHooks.prepareLaunch(env) { apply(route) }
    }
  }

  /// Opens a notification's chat, unless it was deleted since the notification was posted.
  private func openFromNotification(_ id: UUID) async {
    guard (try? await env.store.conversationTitle(id)) != nil else { return }  // An error counts as deleted: nothing opens.
    env.navigator.open(id)
  }

  /// Applies a DEBUG launch route (Release builds never get one).
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
      // This opens only the chat; nothing here opens the full-screen viewer.
      navigator.path = [id]
    case .onboarding:
      navigator.needsOnboarding = true
    }
  }
}
