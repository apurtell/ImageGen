#if DEBUG
import UIKit
import UniformTypeIdentifiers

/// The single entry point from non-DEBUG code into DebugSupport/ (plan §2.6). The Release branch
/// below has no-op stubs with the same signatures.
enum DebugHooks {
  /// `-ResetStore 1`: deletes the store, the files and `Logs/` before the log is created.
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {
    guard LaunchOptions.read().resetStore else { return }
    AppEnvironment.deleteAllData(root: root, cachesRoot: cachesRoot)
  }

  /// `-UITestMockGemini 1`: generation and models calls answered in code, with "mock-key".
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

  /// `-ForceNotificationState denied`: what Settings shows as the notification status.
  static var forcedNotificationState: String? { LaunchOptions.read().forceNotificationState }

  /// `-SkipNotificationPrompt 1`: unattended runs aren't blocked by the system alert.
  static var skipNotificationPrompt: Bool { LaunchOptions.read().skipNotificationPrompt }

  /// After launch: seeds demo data (`-SeedDemoData 1`), then returns where `-Scene` asks to go.
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
      // Writing the pasteboard never prompts; the PasteButton then appears.
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

enum DebugHooks {
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {}
  static func mockEnvironment() -> MockEnvironment? { nil }
  static var skipNotificationPrompt: Bool { false }
  static var forcedNotificationState: String? { nil }
  static func prepareLaunch(_ env: AppEnvironment) async -> LaunchRoute? { nil }
}
#endif
