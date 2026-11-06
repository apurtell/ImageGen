import SwiftData
import SwiftUI

/// Application entry point for macOS.
@main
struct ImageGenMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

  init() {
    // Initialize AppEnvironment before the app delegate receives callbacks.
    if !AppEnvironment.isTestHost { _ = AppEnvironment.shared }
  }

  /// Dynamic window title reflecting active conversation context within macOS system window listings.
  private var mainWindowTitle: String {
    (AppEnvironment.isTestHost ? nil : AppEnvironment.shared.navigator.chatTitle) ?? "ImageGen"
  }

  var body: some Scene {
    Window(mainWindowTitle, id: MacAppDelegate.mainWindowID) {
      if AppEnvironment.isTestHost {
        // Stay inert when hosting unit tests.
        Color.clear
      } else {
        RootView()
          .frame(minWidth: MainWindowSizing.minimum.width, minHeight: MainWindowSizing.minimum.height)
          .environment(AppEnvironment.shared)
          .environment(AppEnvironment.shared.navigator)
          .environment(AppEnvironment.shared.developerMenu)
          .modelContainer(AppEnvironment.shared.container)
      }
    }
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.presented)
    .defaultWindowPlacement { _, context in
      WindowPlacement(.center, size: MainWindowSizing.defaultSize(visible: context.defaultDisplay.visibleRect.size))
    }
    .commands { MacCommands(env: AppEnvironment.isTestHost ? nil : AppEnvironment.shared) }

    // Auxiliary window scene enabling concurrent diagnostic log inspection.
    Window(LogWindow.title, id: LogWindow.id) {
      if !AppEnvironment.isTestHost {
        LogWindow(model: AppEnvironment.shared.developerMenu)
      }
    }
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .defaultSize(width: 760, height: 560)

    Settings {
      if AppEnvironment.isTestHost {
        Color.clear
      } else {
        let env = AppEnvironment.shared
        MacSettingsView(keyModel: env.apiKeySectionModel(), model: env.settingsModel())
          .environment(env)
          .environment(env.navigator)
          .modelContainer(env.container)
      }
    }
  }
}

/// Initial sizing geometry and bounds calculations for the primary macOS application window.
enum MainWindowSizing {
  static let minimum = CGSize(width: 800, height: 560)

  /// Calculates initial window dimensions proportional to usable display bounds while enforcing
  /// minimum size constraints.
  static func defaultSize(visible: CGSize) -> CGSize {
    CGSize(
      width: min(max(visible.width / 2, minimum.width), visible.width),
      height: min(max(visible.height / 2, minimum.height), visible.height))
  }
}
