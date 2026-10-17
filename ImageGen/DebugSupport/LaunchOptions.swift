#if DEBUG
import Foundation

/// Configuration options parsed from application launch arguments and `UserDefaults` argument domains.
///
/// Drives automated test harnesses, mock Gemini transport protocols, deterministic demo data seeding,
/// and automated navigation routing for UI test automation and screenshot capture.
struct LaunchOptions: Sendable, Equatable {
  /// Diagnostic mock response scenarios simulated by `MockGeminiURLProtocol`.
  enum Scenario: String, Sendable, CaseIterable {
    case success, textOnly, twoImages, promptRefused, imageSafety, imageSafetyThenSuccess, imageOther, empty, malformed
    case rateLimitThenSuccess, badRequest, notFound, keyRejected, civicRejectedOnce, lowRes, wrongAspect
  }

  /// Enables in-memory mock Gemini transport without external network traffic.
  var mockGemini = false
  var mockScenario: Scenario = .success
  /// Synthetic latency delay injected before generating mock responses.
  var mockLatency: Double = 2
  var seedDemoData = false
  /// Purges persisted database and asset storage during initialization.
  var resetStore = false
  /// Initial navigation destination specified via launch arguments.
  var scene: String?
  var seedPasteboardImage = false
  var forceNotificationState: String?
  var skipNotificationPrompt = false
  var seedLargeChat = false
  /// Desired initial interface orientation for automated capture.
  var orientation: String?

  /// Parses active launch options from user defaults, falling back to standard default values.
  static func read(_ ud: UserDefaults = .standard) -> LaunchOptions {
    var o = LaunchOptions()
    o.mockGemini = ud.bool(forKey: "UITestMockGemini")
    o.mockScenario = ud.string(forKey: "MockScenario").flatMap(Scenario.init(rawValue:)) ?? .success
    if ud.object(forKey: "MockLatency") != nil { o.mockLatency = max(0, ud.double(forKey: "MockLatency")) }
    o.seedDemoData = ud.bool(forKey: "SeedDemoData")
    o.resetStore = ud.bool(forKey: "ResetStore")
    o.scene = ud.string(forKey: "Scene")
    o.seedPasteboardImage = ud.bool(forKey: "SeedPasteboardImage")
    o.forceNotificationState = ud.string(forKey: "ForceNotificationState")
    o.skipNotificationPrompt = ud.bool(forKey: "SkipNotificationPrompt")
    o.seedLargeChat = ud.bool(forKey: "SeedLargeChat")
    o.orientation = ud.string(forKey: "Orientation")
    return o
  }
}

/// Symbolic destination routes resolved from launch argument scene specifications.
enum SceneRoute: Equatable {
  case chatList
  case chat(String)
  case settings
  case settingsModels
  case viewer(String)
  case onboarding

  /// Resolves a scene route from a formatted argument string.
  init?(rawValue: String) {
    switch rawValue {
    case "chatList": self = .chatList
    case "settings": self = .settings
    case "settings:models": self = .settingsModels
    case "onboarding": self = .onboarding
    case _ where rawValue.hasPrefix("chat:"): self = .chat(String(rawValue.dropFirst(5)))
    case _ where rawValue.hasPrefix("viewer:"): self = .viewer(String(rawValue.dropFirst(7)))
    default: return nil
    }
  }

  /// Resolves the concrete application navigation route using active demo seed mappings.
  func launchRoute(keys: [String: UUID]) -> LaunchRoute? {
    switch self {
    case .chatList: .chatList
    case .chat(let key): keys[key].map { .chat($0) }
    case .settings: .settings
    case .settingsModels: .settingsModels
    case .viewer(let key): keys[key].map { .viewer($0) }
    case .onboarding: .onboarding
    }
  }
}
#endif
