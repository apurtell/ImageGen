#if DEBUG
import Foundation

/// DEBUG launch options (plan §2.6), read from `UserDefaults`, which holds both launch arguments
/// (`-UITestMockGemini 1`) and persisted defaults. Scenes and seeding are wired in M5.
///
/// iOS puts each `-Name value` pair from the launch arguments into the `UserDefaults` argument
/// domain for that run only. So a UI test, a simulator script or an Xcode scheme can set an option
/// without code, and `read` sees an argument and a stored default the same way.
///
/// Place in the design: `DebugHooks` calls `read` at each hook, and acts on the options. This is the
/// whole DEBUG test harness surface; a Release build contains none of it. The value is a plain struct
/// read at call time, so it is `Sendable` and has no shared state.
struct LaunchOptions: Sendable, Equatable {
  /// `-MockScenario <name>`: what `MockGeminiURLProtocol` returns. The plan's table (§2.6) describes
  /// each case. The raw value is the name on the command line.
  enum Scenario: String, Sendable, CaseIterable {
    case success, textOnly, twoImages, promptRefused, imageSafety, imageSafetyThenSuccess, imageOther, empty, malformed
    case rateLimitThenSuccess, badRequest, notFound, keyRejected, civicRejectedOnce, lowRes, wrongAspect
  }

  /// `-UITestMockGemini 1`: answer the API in code, with an in-memory key.
  var mockGemini = false
  var mockScenario: Scenario = .success
  /// `-MockLatency <seconds>`: the delay before each mock response.
  var mockLatency: Double = 2
  var seedDemoData = false
  /// `-ResetStore 1`: delete all data at the start of launch, before the activity log exists.
  var resetStore = false
  /// `-Scene <name>`: the screen to open after launch (`SceneRoute`).
  var scene: String?
  var seedPasteboardImage = false
  var forceNotificationState: String?
  var skipNotificationPrompt = false
  var seedLargeChat = false
  /// `-Orientation landscape`: rotates the scene at launch (screenshots; the simulator tool can't rotate).
  var orientation: String?

  /// Reads every option. A missing or unknown value gives the default, never an error.
  static func read(_ ud: UserDefaults = .standard) -> LaunchOptions {
    var o = LaunchOptions()
    o.mockGemini = ud.bool(forKey: "UITestMockGemini")
    o.mockScenario = ud.string(forKey: "MockScenario").flatMap(Scenario.init(rawValue:)) ?? .success
    // `double(forKey:)` returns 0 for a missing key, so the check keeps the 2 s default.
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
///
/// A seed key (for example `chat:lighthouse`) names a demo chat by a stable word. `launchRoute` turns
/// the key into the chat's real ID with the keys that `DemoSeeder` stored. The app's own navigation
/// type is `LaunchRoute`; this type exists only in DEBUG builds.
enum SceneRoute: Equatable {
  case chatList
  case chat(String)
  case settings
  case settingsModels
  case viewer(String)
  case onboarding

  /// nil for an unknown name. Swift note: `init?` is an initializer that can fail and return nil.
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

  /// nil when a chat or viewer key has no seeded chat, so the app opens normally.
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
