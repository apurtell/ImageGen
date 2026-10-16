import SwiftUI

@main
struct ImageGenApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Creates the environment (and the background session) before didFinishLaunching runs.
    if !AppEnvironment.isTestHost { _ = AppEnvironment.shared }
  }

  var body: some Scene {
    WindowGroup {
      if AppEnvironment.isTestHost {
        // Unit tests are hosted by the app; the host stays inert (plan §2.2).
        Color.clear
      } else {
        NavigationStack {
          Text("Chats")
            .navigationTitle("Chats")
        }
        .onAppear { AppEnvironment.shared.firstFrameAppeared() }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard !AppEnvironment.isTestHost else { return }
      AppEnvironment.shared.scenePhaseChanged(isActive: phase == .active, isBackground: phase == .background)
    }
  }
}
