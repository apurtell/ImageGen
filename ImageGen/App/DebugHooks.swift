#if DEBUG
import UIKit
import UniformTypeIdentifiers

/// Encapsulates debug harness integrations, mock environments, and test automation hooks.
///
/// Production and release builds compile an empty stub implementation of this enum, ensuring that
/// test-only dependencies, mock endpoints, and fixture seeders are excluded from release binaries.
enum DebugHooks {
  /// Purges persisted database records, image caches, and activity logs when requested by launch configuration.
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {
    guard LaunchOptions.read().resetStore else { return }
    AppEnvironment.deleteAllData(root: root, cachesRoot: cachesRoot)
  }

  /// Instantiates mock environment dependencies using ephemeral network session configurations
  /// and mock URL protocols when simulator mock flags are supplied.
  static func mockEnvironment() -> MockEnvironment? {
    let options = LaunchOptions.read()
    guard options.mockGemini else { return nil }
    MockGeminiURLProtocol.configure(scenario: options.mockScenario, latency: options.mockLatency)
    let configuration = URLSessionTransport.ephemeralConfiguration(protocolClasses: [MockGeminiURLProtocol.self])
    return MockEnvironment(
      transportConfiguration: configuration, modelsProtocolClasses: [MockGeminiURLProtocol.self],
      keyStore: InMemoryKeyStore(key: "mock-key", registry: SecretRegistry()),
      description: "on (\(options.mockScenario.rawValue), \(options.mockLatency) s)")
  }

  /// Overrides notification authorization state for UI testing and visual verification.
  static var forcedNotificationState: String? { LaunchOptions.read().forceNotificationState }

  /// Determines whether system notification permission prompts should be suppressed during automated test runs.
  static var skipNotificationPrompt: Bool { LaunchOptions.read().skipNotificationPrompt }

  /// Seeds demonstration conversations and pre-populates pasteboard assets prior to initial scene presentation.
  static func prepareLaunch(_ env: AppEnvironment) async -> LaunchRoute? {
    let options = LaunchOptions.read()
    var keys: [String: UUID] = DemoSeeder.storedKeys()
    if options.seedDemoData {
      keys = await DemoSeeder.seedIfEmpty(store: env.store, files: env.files)
    }
    if options.seedLargeChat, let id = await DemoSeeder.seedLargeChat(store: env.store, files: env.files) {
      keys["large"] = id
    }
    if options.seedPasteboardImage {
      let jpeg = MockImageRenderer.jpeg(width: 1024, height: 768, prompt: "Pasted image", caption: "from the pasteboard")
      UIPasteboard.general.setData(jpeg, forPasteboardType: UTType.jpeg.identifier)
    }
    if options.orientation == "landscape" {
      await MainActor.run {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?
          .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
      }
    }
    guard let scene = options.scene.flatMap(SceneRoute.init(rawValue:)) else { return nil }
    return scene.launchRoute(keys: keys)
  }
}
#else
import Foundation

/// Inert stub implementation compiled into release configurations.
enum DebugHooks {
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {}
  static func mockEnvironment() -> MockEnvironment? { nil }
  static var skipNotificationPrompt: Bool { false }
  static var forcedNotificationState: String? { nil }
  static func prepareLaunch(_ env: AppEnvironment) async -> LaunchRoute? { nil }
}
#endif
