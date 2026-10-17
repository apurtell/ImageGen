import SwiftData
import SwiftUI

/// Application entry point and composition boundary.
///
/// Configures the root `WindowGroup`, coordinates system lifecycle transitions with `AppEnvironment`,
/// binds the shared `AppDelegate` for UIKit background transfer events, and injects core dependencies
/// and the SwiftData `ModelContainer` into the presentation hierarchy.
@main
struct ImageGenApp: App {
  /// Bridges UIKit application lifecycle and background transfer delegate events.
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// Tracks system scene phase transitions.
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Eagerly initializes runtime singletons and background session routing prior to initial delegate callbacks.
    if !AppEnvironment.isTestHost { _ = AppEnvironment.shared }
  }

  var body: some Scene {
    WindowGroup {
      if AppEnvironment.isTestHost {
        // Renders an inert view hierarchy when executing within a test host context.
        Color.clear
      } else {
        // Injects shared dependencies and the main-actor model container for declarative query bindings.
        RootView()
          .environment(AppEnvironment.shared)
          .environment(AppEnvironment.shared.navigator)
          .environment(AppEnvironment.shared.developerMenu)
          .modelContainer(AppEnvironment.shared.container)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard !AppEnvironment.isTestHost else { return }
      AppEnvironment.shared.scenePhaseChanged(isActive: phase == .active, isBackground: phase == .background)
    }
  }
}
