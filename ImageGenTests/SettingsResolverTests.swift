import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct SettingsResolverTests {
  let defaults = GenerationDefaults()
  let flash = ModelCatalog.defaultModelID

  func resolve(_ o: ChatOverrides = ChatOverrides(), _ d: GenerationDefaults? = nil) -> EffectiveSettings {
    GenerationSettingsResolver.resolve(o, d ?? defaults, catalog: ModelCatalog.descriptor(for:))
  }

  @Test func defaultsAre16x9And2K() {
    let s = resolve()
    #expect(s.modelID == flash)
    #expect(s.aspectRatio == .r16x9)
    #expect(s.imageSize == .s2K)
    #expect(s.threshold == .blockNone)
    #expect(s.categories == HarmCategory.allCases)
    #expect(s.includeTextModality)
    #expect(s.coercions.isEmpty)
  }

  @Test(arguments: [
    ChatOverrides(modelID: "gemini-nano-banana-2.1", aspectRatio: .r9x16, imageSize: .s4K),
    ChatOverrides(modelID: nil, aspectRatio: .r21x9, imageSize: .s512),
    ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r3x2, imageSize: .s1K),
  ])
  func perChatOverridesWin(_ o: ChatOverrides) {
    let s = resolve(o, GenerationDefaults(aspectRatio: .r1x1, imageSize: .s1K))
    #expect(s.modelID == (o.modelID ?? flash))
    #expect(s.aspectRatio == o.aspectRatio)
    #expect(s.imageSize == o.imageSize)
    #expect(s.coercions.isEmpty)
  }

  @Test func clearingOverrideFallsBackToDefault() {
    let d = GenerationDefaults(aspectRatio: .r4x3, imageSize: .s1K)
    let overridden = resolve(ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r9x16, imageSize: .s4K), d)
    #expect(overridden.aspectRatio == .r9x16)
    let cleared = resolve(ChatOverrides(), d)
    #expect(cleared.modelID == flash)
    #expect(cleared.aspectRatio == .r4x3)
    #expect(cleared.imageSize == .s1K)
  }

  @Test func proCoerces1x8To16x9() {
    let s = resolve(ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r1x8))
    #expect(s.aspectRatio == .r16x9)
    #expect(s.coercions == [Coercion(field: .aspectRatio, requested: "1:8", used: "16:9", reason: s.coercions.first!.reason)])
  }

  @Test func proCoerces512To1K() {
    let s = resolve(ChatOverrides(modelID: "gemini-3-pro-image", imageSize: .s512))
    #expect(s.imageSize == .s1K)
    #expect(s.coercions.map(\.field) == [.imageSize])
    #expect(s.coercions.first?.used == "1K")
  }

  @Test func flashLiteCoerces2KTo1K() {
    let s = resolve(ChatOverrides(modelID: "gemini-3.1-flash-lite-image"))
    #expect(s.imageSize == .s1K)
    #expect(s.aspectRatio == .r16x9)
    #expect(s.coercions.map(\.field) == [.imageSize])
  }

  @Test func flashLiteCoerces1x8To16x9() {
    let s = resolve(ChatOverrides(modelID: "gemini-3.1-flash-lite-image", aspectRatio: .r1x8, imageSize: .s4K))
    #expect(s.aspectRatio == .r16x9)
    #expect(s.imageSize == .s1K)
    #expect(s.coercions.map(\.field) == [.aspectRatio, .imageSize])
  }

  @Test func flash25OmitsImageSize() {
    let s = resolve(ChatOverrides(modelID: "gemini-2.5-flash-image"))
    #expect(s.aspectRatio == .r16x9)
    #expect(s.imageSize == nil)
    #expect(s.coercions.first { $0.field == .imageSize }?.used == nil)
  }

  @Test(arguments: ImageSize.allCases)
  func oneKOnlyCapabilityCoercesAll(size: ImageSize) {
    let oneK = ModelDescriptor(
      id: "one-k", displayName: "One K", shortName: "1K",
      capability: ModelCapability(aspectRatios: [.r1x1], imageSizes: [.s1K], sendsImageConfig: true, highFidelityInputLimit: 14),
      role: .custom)
    var d = defaults
    d.enabledModelIDs.insert("one-k")
    let s = GenerationSettingsResolver.resolve(ChatOverrides(modelID: "one-k", imageSize: size), d) { _ in oneK }
    #expect(s.imageSize == .s1K)
    // Coerces unsupported 16:9 aspect ratio to model-supported 1:1.
    #expect(s.aspectRatio == .r1x1)
    #expect(s.coercions.contains { $0.field == .imageSize } == (size != .s1K))
  }

  @Test func nearestSizePrefersLarger() {
    let twoAndFour = ModelDescriptor(
      id: "x", displayName: "x", shortName: "x",
      capability: ModelCapability(aspectRatios: AspectRatio.allCases, imageSizes: [.s512, .s4K], sendsImageConfig: true, highFidelityInputLimit: 14),
      role: .custom)
    var d = defaults
    d.enabledModelIDs.insert("x")
    // Distance evaluation: 2K resolves to closest neighbor 4K; 1K resolves to 512.
    #expect(GenerationSettingsResolver.resolve(ChatOverrides(modelID: "x", imageSize: .s2K), d) { _ in twoAndFour }.imageSize == .s4K)
    #expect(GenerationSettingsResolver.resolve(ChatOverrides(modelID: "x", imageSize: .s1K), d) { _ in twoAndFour }.imageSize == .s512)
    let oneAndFour = ModelDescriptor(
      id: "y", displayName: "y", shortName: "y",
      capability: ModelCapability(aspectRatios: AspectRatio.allCases, imageSizes: [.s1K, .s4K], sendsImageConfig: true, highFidelityInputLimit: 14),
      role: .custom)
    d.enabledModelIDs.insert("y")
    // Tie-breaking behavior: equidistant candidate sizes resolve in favor of the larger option.
    #expect(GenerationSettingsResolver.resolve(ChatOverrides(modelID: "y", imageSize: .s2K), d) { _ in oneAndFour }.imageSize == .s4K)
  }

  @Test func customModelPassesThrough4K21x9() {
    var d = defaults
    d.enabledModelIDs.insert("gemini-x-test")
    let s = resolve(ChatOverrides(modelID: "gemini-x-test", aspectRatio: .r21x9, imageSize: .s4K), d)
    #expect(s.modelID == "gemini-x-test")
    #expect(s.aspectRatio == .r21x9)
    #expect(s.imageSize == .s4K)
    #expect(s.coercions.isEmpty)
  }

  @Test func disabledModelOverrideFallsBackToFlash() {
    var d = defaults
    d.enabledModelIDs.remove("gemini-3-pro-image")
    let s = resolve(ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r1x8, imageSize: .s512), d)
    #expect(s.modelID == flash)
    // Default model accommodates requested aspect ratio and size; only the model identifier undergoes coercion.
    #expect(s.aspectRatio == .r1x8)
    #expect(s.imageSize == .s512)
    #expect(s.coercions.map(\.field) == [.model])
    #expect(s.coercions.first?.requested == "gemini-3-pro-image")
    #expect(s.coercions.first?.used == flash)
  }

  @Test func removedCustomIDOverrideFallsBackToFlash() {
    let s = resolve(ChatOverrides(modelID: "gemini-x-removed"))
    #expect(s.modelID == flash)
    #expect(s.coercions.map(\.field) == [.model])
  }

  @Test func flashOverrideAlwaysAllowed() {
    var d = defaults
    d.enabledModelIDs = []
    let s = resolve(ChatOverrides(modelID: flash), d)
    #expect(s.modelID == flash)
    #expect(s.coercions.isEmpty)
  }

  @Test func coercionIsReported() {
    let s = resolve(ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r8x1, imageSize: .s512))
    #expect(s.coercions.count == 2)
    #expect(s.coercions.allSatisfy { !$0.reason.isEmpty })
    #expect(s.coercions.map(\.requested) == ["8:1", "512"])
    #expect(s.coercions.map(\.used) == ["16:9", "1K"])
  }

  @Test func omitCivicGivesFourCategories() {
    let s = resolve(ChatOverrides(), GenerationDefaults(threshold: .blockOnlyHigh, omitCivicIntegrity: true))
    #expect(s.categories == [.harassment, .hateSpeech, .sexuallyExplicit, .dangerousContent])
    #expect(s.threshold == .blockOnlyHigh)
  }

  @Test func textModalityFollowsDefaults() {
    #expect(!resolve(ChatOverrides(), GenerationDefaults(includeTextModality: false)).includeTextModality)
  }
}
