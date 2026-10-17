import SwiftData
import SwiftUI

/// The app's entry point. `@main` marks the type that iOS starts.
///
/// A SwiftUI `App` describes the app's scenes (here, one window) the way a `View` describes a screen.
/// It creates `AppEnvironment.shared` early, attaches `AppDelegate` for the UIKit events that SwiftUI
/// does not expose, injects the environment into the view tree, and reports scene phase changes.
/// Everything here runs on the main actor. See the primer, *SwiftUI: the user interface* and
/// *iOS application lifecycle*.
@main
struct ImageGenApp: App {
  /// `@UIApplicationDelegateAdaptor` makes SwiftUI create one `AppDelegate` and give it the UIKit
  /// delegate calls.
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// The window's phase: active, inactive or background. SwiftUI updates it.
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
        // `.environment(_:)` makes each object readable by every view below with `@Environment`.
        // `.modelContainer` gives SwiftUI's `@Query` lists the main-actor view of the database.
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
