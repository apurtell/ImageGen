import Foundation
import Testing

@testable import ImageGen

@MainActor
@Suite(.tags(.pure))
struct AppSettingsTests {
  /// A fresh, private defaults domain per test.
  final class Defaults {
    let name = "ImageGenTests.\(UUID().uuidString)"
    let ud: UserDefaults
    init() { ud = UserDefaults(suiteName: name)! }
    deinit {
      ud.removePersistentDomain(forName: name)
      let plist = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/\(name).plist")
      try? FileManager.default.removeItem(at: plist)
    }
  }

  @Test func defaultsAre16x9And2K() {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    #expect(s.defaultAspectRatio == .r16x9)
    #expect(s.defaultImageSize == .s2K)
    #expect(s.generationDefaults().aspectRatio == .r16x9)
    #expect(s.generationDefaults().imageSize == .s2K)
  }

  @Test func defaultsBlockNoneAnd2048AndTextOn() {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    #expect(s.safetyThreshold == .blockNone)
    #expect(s.maxUploadLongEdge == 2048)
    #expect(s.includeTextModality)
    #expect(!s.omitCivicIntegrity)
    #expect(s.notifyOnBackgroundCompletion)
    #expect(s.customModelIDs.isEmpty)
    #expect(s.modelAvailabilityCache == nil)
    #expect(s.generationDefaults() == GenerationDefaults())
  }

  @Test func persistsAcrossInstances() {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    s.defaultAspectRatio = .r1x1
    s.defaultImageSize = .s1K
    s.safetyThreshold = .blockLowAndAbove
    s.maxUploadLongEdge = 4096
    s.includeTextModality = false
    s.omitCivicIntegrity = true
    s.customModelIDs = ["gemini-x-test"]
    s.notifyOnBackgroundCompletion = false
    s.setModel("gemini-3-pro-image", enabled: false)
    let cache = ModelAvailabilityCache(models: ["gemini-3.1-flash-image": true], checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
    s.modelAvailabilityCache = cache

    let t = AppSettings(defaults: d.ud)
    #expect(t.defaultAspectRatio == .r1x1)
    #expect(t.defaultImageSize == .s1K)
    #expect(t.safetyThreshold == .blockLowAndAbove)
    #expect(t.maxUploadLongEdge == 4096)
    #expect(!t.includeTextModality)
    #expect(t.omitCivicIntegrity)
    #expect(t.customModelIDs == ["gemini-x-test"])
    #expect(!t.notifyOnBackgroundCompletion)
    #expect(!t.enabledModelIDs.contains("gemini-3-pro-image"))
    #expect(t.modelAvailabilityCache == cache)
  }

  @Test func invalidLongEdgeFallsBackTo2048() {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    s.maxUploadLongEdge = 1000
    #expect(s.generationDefaults().maxUploadLongEdge == 2048)
    #expect(AppSettings(defaults: d.ud).maxUploadLongEdge == 2048)
  }

  @Test func flashCannotBeDisabled() {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    s.setModel(ModelCatalog.defaultModelID, enabled: false)
    #expect(s.enabledModelIDs.contains(ModelCatalog.defaultModelID))
    s.enabledModelIDs = []
    #expect(s.enabledModelIDs == [ModelCatalog.defaultModelID])
    d.ud.set([ModelCatalog.defaultModelID], forKey: AppSettings.Key.disabledCatalogModelIDs)
    #expect(AppSettings.readDefaults(d.ud).enabledModelIDs.contains(ModelCatalog.defaultModelID))
  }

  @Test func allCatalogModelsEnabledByDefault() {
    let d = Defaults()
    #expect(AppSettings(defaults: d.ud).enabledModelIDs == ModelCatalog.builtInIDs)
  }

  @Test func enabledModelIDsIncludeCustomIDsAndFlash() {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    s.customModelIDs = ["gemini-x-test", "gemini-y-test"]
    s.setModel("gemini-2.5-flash-image", enabled: false)
    let enabled = s.generationDefaults().enabledModelIDs
    #expect(enabled.isSuperset(of: ["gemini-x-test", "gemini-y-test", ModelCatalog.defaultModelID]))
    #expect(!enabled.contains("gemini-2.5-flash-image"))
    s.setModel("gemini-2.5-flash-image", enabled: true)
    #expect(s.enabledModelIDs.contains("gemini-2.5-flash-image"))
  }

  @Test func nonisolatedReadMatches() async {
    let d = Defaults()
    let s = AppSettings(defaults: d.ud)
    s.defaultAspectRatio = .r21x9
    s.defaultImageSize = .s4K
    s.omitCivicIntegrity = true
    s.customModelIDs = ["gemini-x-test"]
    s.setModel("gemini-3-pro-image", enabled: false)
    let expected = s.generationDefaults()
    let name = d.name
    let fromBackground = await Task.detached { AppSettings.readDefaults(UserDefaults(suiteName: name)!) }.value
    #expect(fromBackground == expected)
  }
}
