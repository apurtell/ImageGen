import SwiftData
import SwiftUI

/// Application entry point for macOS.
///
/// Sets up the main window group, connects `MacAppDelegate`, passes scene phase updates
/// to `AppEnvironment`, and injects shared dependencies and the SwiftData container.
@main
struct ImageGenMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // Initialize AppEnvironment before the app delegate receives callbacks.
    if !AppEnvironment.isTestHost { _ = AppEnvironment.shared }
  }

  var body: some Scene {
    WindowGroup {
      if AppEnvironment.isTestHost {
        // Stay inert when hosting unit tests.
        Color.clear
      } else {
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
