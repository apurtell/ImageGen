import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct VocabularyTests {
  @Test func allAspectRatioRawValues() {
    #expect(AspectRatio.allCases.map(\.rawValue) == [
      "1:1", "1:4", "4:1", "1:8", "8:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9",
    ])
    #expect(AspectRatio.r16x9.ratio == 16.0 / 9.0)
    #expect(AspectRatio.r16x9.group == .landscape)
    #expect(AspectRatio.r1x1.group == .square)
    #expect(AspectRatio.r9x16.group == .portrait)
    #expect(AspectRatio.r1x8.group == .extreme)
    #expect(AspectRatio.standard.count == 10)
  }

  @Test func imageSizeRawValuesUppercaseK() {
    #expect(ImageSize.allCases.map(\.rawValue) == ["512", "1K", "2K", "4K"])
    #expect(ImageSize.s512.displayName == "512 px")
    #expect(ImageSize.s1K.displayName == "1K (~1 MP)")
  }

  @Test func safetyThresholdRawValues() {
    #expect(SafetyThreshold.allCases.map(\.rawValue) == [
      "BLOCK_NONE", "BLOCK_ONLY_HIGH", "BLOCK_MEDIUM_AND_ABOVE", "BLOCK_LOW_AND_ABOVE",
    ])
  }

  @Test func harmCategoryRawValuesAndOrder() {
    #expect(HarmCategory.allCases.map(\.rawValue) == [
      "HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH", "HARM_CATEGORY_SEXUALLY_EXPLICIT",
      "HARM_CATEGORY_DANGEROUS_CONTENT", "HARM_CATEGORY_CIVIC_INTEGRITY",
    ])
  }

  @Test func selectionReasonNoImageStoresNone() throws {
    #expect(SelectionReason.noImage.rawValue == "none")
    #expect(SelectionReason(rawValue: "none") == .noImage)
    let json = try JSONEncoder().encode([SelectionReason.noImage])
    #expect(String(decoding: json, as: UTF8.self) == #"["none"]"#)
  }

  @Test func flashSupportsAll14AndAllSizes() {
    let flash = ModelCatalog.descriptor(for: "gemini-3.1-flash-image")
    #expect(flash.capability.aspectRatios == AspectRatio.allCases)
    #expect(flash.capability.imageSizes == [.s512, .s1K, .s2K, .s4K])
    #expect(flash.role == .defaultMandatory)
    #expect(flash.shortName == "3.1 Flash")
  }

  @Test func proExcludesExtremeAndNo512() {
    for id in ["gemini-3-pro-image", "gemini-3-pro-image-preview"] {
      let pro = ModelCatalog.descriptor(for: id).capability
      #expect(pro.aspectRatios.count == 10)
      #expect(!pro.aspectRatios.contains { $0.group == .extreme })
      #expect(pro.imageSizes == [.s1K, .s2K, .s4K])
    }
    #expect(ModelCatalog.descriptor(for: "gemini-3-pro-image-preview").role == .legacyIfListed)
  }

  @Test func nanoBanana21No512() {
    let c = ModelCatalog.descriptor(for: "gemini-nano-banana-2.1").capability
    #expect(c.aspectRatios.count == 14)
    #expect(c.imageSizes == [.s1K, .s2K, .s4K])
  }

  @Test func flashLiteOnly1KAndStandardRatios() {
    let c = ModelCatalog.descriptor(for: "gemini-3.1-flash-lite-image").capability
    #expect(c.aspectRatios == AspectRatio.standard)
    #expect(c.imageSizes == [.s1K])
  }

  @Test func flash25OmitsImageSize() {
    let c = ModelCatalog.descriptor(for: "gemini-2.5-flash-image").capability
    #expect(c.imageSizes.isEmpty)
    #expect(c.aspectRatios == AspectRatio.standard)
    #expect(c.sendsImageConfig)
  }

  @Test(arguments: [
    ("gemini-3.1-flash-image", 10), ("gemini-3-pro-image", 5), ("gemini-nano-banana-2.1", 10),
    ("gemini-3.1-flash-lite-image", 14), ("gemini-2.5-flash-image", 3), ("gemini-3-pro-image-preview", 5),
    ("my-custom-model", 14),
  ])
  func highFidelityLimitsMatchDesign(id: String, limit: Int) {
    #expect(ModelCatalog.descriptor(for: id).capability.highFidelityInputLimit == limit)
  }

  @Test func unknownIDGetsCustomCapability() {
    let d = ModelCatalog.descriptor(for: "gemini-x-test")
    #expect(d.role == .custom)
    #expect(d.displayName == "gemini-x-test")
    #expect(d.capability.aspectRatios == AspectRatio.allCases)
    #expect(d.capability.imageSizes == [.s1K, .s2K, .s4K])
    #expect(d.capability.sendsImageConfig)
  }

  @Test func defaultModelIsFlash() {
    #expect(ModelCatalog.defaultModelID == "gemini-3.1-flash-image")
    #expect(ModelCatalog.builtIns.first?.id == ModelCatalog.defaultModelID)
    #expect(ModelCatalog.builtIns.allSatisfy { $0.capability.sendsImageConfig })
  }

  @Test func everyBuiltInEnabledByDefault() {
    for d in ModelCatalog.builtIns {
      if case .optional(let enabled) = d.role { #expect(enabled, "\(d.id)") }
    }
    #expect(ModelCatalog.builtIns.filter { $0.role == .optional(enabledByDefault: true) }.count == 4)
    #expect(GenerationDefaults().enabledModelIDs == ModelCatalog.builtInIDs)
    #expect(ModelCatalog.builtInIDs.count == 6)
  }

  @Test func requestStateTerminalAndLive() {
    let terminal: Set<RequestState> = [.succeeded, .refused, .failed, .cancelled, .interrupted]
    for s in RequestState.allCases {
      #expect(s.isTerminal == terminal.contains(s))
      #expect(s.isLive == !terminal.contains(s))
    }
  }
}
