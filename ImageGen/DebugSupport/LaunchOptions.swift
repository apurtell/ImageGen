#if DEBUG
import Foundation

/// DEBUG launch options (plan §2.6), read from `UserDefaults`, which holds both launch arguments
/// (`-UITestMockGemini 1`) and persisted defaults. Scenes and seeding are wired in M5.
struct LaunchOptions: Sendable, Equatable {
  enum Scenario: String, Sendable, CaseIterable {
    case success, textOnly, twoImages, promptRefused, imageSafety, imageSafetyThenSuccess, imageOther, empty, malformed
    case rateLimitThenSuccess, badRequest, notFound, keyRejected, civicRejectedOnce, lowRes, wrongAspect
  }

  var mockGemini = false
  var mockScenario: Scenario = .success
  var mockLatency: Double = 2
  var seedDemoData = false
  var resetStore = false
  var scene: String?
  var seedPasteboardImage = false
  var forceNotificationState: String?
  var skipNotificationPrompt = false
  var seedLargeChat = false
  /// `-Orientation landscape`: rotates the scene at launch (screenshots; the simulator tool can't rotate).
  var orientation: String?

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

/// `-Scene <name>` (plan §2.6).
enum SceneRoute: Equatable {
  case chatList
  case chat(String)
  case settings
  case settingsModels
  case viewer(String)
  case onboarding

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
