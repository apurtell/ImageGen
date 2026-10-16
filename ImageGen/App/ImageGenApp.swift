import SwiftUI

@main
struct ImageGenApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// Unit tests are hosted by the app; under the test host the app shows an inert scene (plan §2.2).
  private static let isTestHost =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  var body: some Scene {
    WindowGroup {
      if Self.isTestHost {
        Color.clear
      } else {
        NavigationStack {
          Text("Chats")
            .navigationTitle("Chats")
        }
      }
    }
  }
}
