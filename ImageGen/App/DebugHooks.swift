#if DEBUG
// `#if DEBUG` is a compile-time condition: this branch exists only in Debug builds, and the `#else`
// branch only in Release builds. The project's lint requires `#if DEBUG` as this file's first code line.
import UIKit
import UniformTypeIdentifiers

/// The single entry point from non-DEBUG code into DebugSupport/ (plan §2.6). The Release branch
/// below has no-op stubs with the same signatures.
///
/// App code calls only these functions, never `LaunchOptions`, `DemoSeeder` or `MockGeminiURLProtocol`
/// directly; the lint enforces that. Each function reads the launch arguments that UI tests and demo
/// runs pass (for example `-UITestMockGemini 1`), through `LaunchOptions.read()`.
enum DebugHooks {
  /// `-ResetStore 1`: deletes the store, the files and `Logs/` before the log is created.
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {
    guard LaunchOptions.read().resetStore else { return }
    AppEnvironment.deleteAllData(root: root, cachesRoot: cachesRoot)
  }

  /// `-UITestMockGemini 1`: generation and models calls answered in code, with "mock-key".
  ///
  /// A background session cannot use a custom `URLProtocol`, so mock mode uses an ephemeral
  /// configuration; the transport then holds delayed retries itself (D§4.6, Retries).
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
  /// `RootView` calls it from its `.task` when it first appears, and applies the route it returns.
  static func prepareLaunch(_ env: AppEnvironment) async -> LaunchRoute? {
    let options = LaunchOptions.read()
    // Seed keys (names of demo chats, saved in `UserDefaults` by an earlier seeding) map to chat IDs,
    // so `-Scene chat:<key>` can name the chat to open.
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

// Release build: the same names, doing nothing, so callers need no `#if` of their own.
enum DebugHooks {
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {}
  static func mockEnvironment() -> MockEnvironment? { nil }
  static var skipNotificationPrompt: Bool { false }
  static var forcedNotificationState: String? { nil }
  static func prepareLaunch(_ env: AppEnvironment) async -> LaunchRoute? { nil }
}
#endif
