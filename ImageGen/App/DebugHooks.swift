#if DEBUG
import Foundation

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
}
#else
import Foundation

enum DebugHooks {
  static func resetBeforeLaunchIfRequested(root: URL, cachesRoot: URL) {}
  static func mockEnvironment() -> MockEnvironment? { nil }
}
#endif
