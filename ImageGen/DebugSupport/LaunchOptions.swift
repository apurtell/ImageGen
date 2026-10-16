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
    return o
  }
}
#endif
