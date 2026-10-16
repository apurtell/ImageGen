import Foundation

// Shared vocabulary for the Gemini wire format (D§2.4, D§2.5). Raw values are the exact API strings.

enum AspectGroup: String, Sendable, Codable, CaseIterable {
  case landscape, square, portrait, extreme
}

enum AspectRatio: String, Sendable, Codable, CaseIterable {
  case r1x1 = "1:1"
  case r1x4 = "1:4"
  case r4x1 = "4:1"
  case r1x8 = "1:8"
  case r8x1 = "8:1"
  case r2x3 = "2:3"
  case r3x2 = "3:2"
  case r3x4 = "3:4"
  case r4x3 = "4:3"
  case r4x5 = "4:5"
  case r5x4 = "5:4"
  case r9x16 = "9:16"
  case r16x9 = "16:9"
  case r21x9 = "21:9"

  /// Composer menu grouping (D§3.5).
  var group: AspectGroup {
    switch self {
    case .r16x9, .r21x9, .r3x2, .r4x3, .r5x4: .landscape
    case .r1x1: .square
    case .r9x16, .r2x3, .r3x4, .r4x5: .portrait
    case .r4x1, .r8x1, .r1x4, .r1x8: .extreme
    }
  }

  /// Width divided by height.
  var ratio: Double {
    let sides = rawValue.split(separator: ":").compactMap { Double($0) }
    return sides[0] / sides[1]
  }

  /// The 10 standard ratios: all 14 without 1:4, 4:1, 1:8 and 8:1 (D§2.5).
  static let standard: [AspectRatio] = allCases.filter { $0.group != .extreme }
}

enum ImageSize: String, Sendable, Codable, CaseIterable {
  case s512 = "512"
  case s1K = "1K"
  case s2K = "2K"
  case s4K = "4K"

  var nominalMegapixels: Double {
    switch self {
    case .s512: 0.262
    case .s1K: 1.05
    case .s2K: 4.19
    case .s4K: 16.8
    }
  }

  var displayName: String {
    switch self {
    case .s512: "512 px"
    case .s1K: "1K (~1 MP)"
    case .s2K: "2K (~4 MP)"
    case .s4K: "4K (~16 MP)"
    }
  }
}

enum SafetyThreshold: String, Sendable, Codable, CaseIterable {
  case blockNone = "BLOCK_NONE"
  case blockOnlyHigh = "BLOCK_ONLY_HIGH"
  case blockMediumAndAbove = "BLOCK_MEDIUM_AND_ABOVE"
  case blockLowAndAbove = "BLOCK_LOW_AND_ABOVE"

  var displayName: String {
    switch self {
    case .blockNone: "Block none"
    case .blockOnlyHigh: "Block only high"
    case .blockMediumAndAbove: "Block medium and above"
    case .blockLowAndAbove: "Block low and above"
    }
  }
}

/// In the pipe's order, which is also the wire order.
enum HarmCategory: String, Sendable, Codable, CaseIterable {
  case harassment = "HARM_CATEGORY_HARASSMENT"
  case hateSpeech = "HARM_CATEGORY_HATE_SPEECH"
  case sexuallyExplicit = "HARM_CATEGORY_SEXUALLY_EXPLICIT"
  case dangerousContent = "HARM_CATEGORY_DANGEROUS_CONTENT"
  case civicIntegrity = "HARM_CATEGORY_CIVIC_INTEGRITY"
}

/// Why an input image was chosen (D§2.2). `noImage` is stored as "none"; the case isn't named
/// `none` because `.none` on an optional would silently mean `Optional.none`.
enum SelectionReason: String, Sendable, Codable, CaseIterable {
  case attachments
  case pinned
  case latest
  case noImage = "none"
}

enum RequestState: String, Sendable, Codable, CaseIterable {
  case preparing, inFlight, retryScheduled, parsing, succeeded, refused, failed, cancelled, interrupted

  var isTerminal: Bool {
    switch self {
    case .succeeded, .refused, .failed, .cancelled, .interrupted: true
    case .preparing, .inFlight, .retryScheduled, .parsing: false
    }
  }

  var isLive: Bool { !isTerminal }
}

struct ModelCapability: Sendable, Equatable {
  var aspectRatios: [AspectRatio]
  /// Empty means the `imageSize` key is omitted.
  var imageSizes: [ImageSize]
  var sendsImageConfig: Bool
  /// Soft tray-warning threshold (D§2.5); 14 means no soft warning.
  var highFidelityInputLimit: Int
}

struct ModelDescriptor: Sendable, Equatable, Identifiable {
  enum Role: Sendable, Equatable {
    case defaultMandatory
    case optional(enabledByDefault: Bool)
    case legacyIfListed
    case custom
  }

  var id: String
  var displayName: String
  var shortName: String
  var capability: ModelCapability
  var role: Role
}

enum ModelCatalog {
  static let defaultModelID = "gemini-3.1-flash-image"

  private static let proCapability = ModelCapability(
    aspectRatios: AspectRatio.standard, imageSizes: [.s1K, .s2K, .s4K],
    sendsImageConfig: true, highFidelityInputLimit: 5)

  static let builtIns: [ModelDescriptor] = [
    ModelDescriptor(
      id: "gemini-3.1-flash-image", displayName: "Gemini 3.1 Flash Image", shortName: "3.1 Flash",
      capability: ModelCapability(
        aspectRatios: AspectRatio.allCases, imageSizes: ImageSize.allCases,
        sendsImageConfig: true, highFidelityInputLimit: 10),
      role: .defaultMandatory),
    ModelDescriptor(
      id: "gemini-3-pro-image", displayName: "Gemini 3 Pro Image", shortName: "3 Pro",
      capability: proCapability, role: .optional(enabledByDefault: true)),
    ModelDescriptor(
      id: "gemini-nano-banana-2.1", displayName: "Nano Banana 2.1", shortName: "2.1",
      capability: ModelCapability(
        aspectRatios: AspectRatio.allCases, imageSizes: [.s1K, .s2K, .s4K],
        sendsImageConfig: true, highFidelityInputLimit: 10),
      role: .optional(enabledByDefault: true)),
    ModelDescriptor(
      id: "gemini-3.1-flash-lite-image", displayName: "Gemini 3.1 Flash Lite Image",
      shortName: "3.1 Flash Lite",
      capability: ModelCapability(
        aspectRatios: AspectRatio.standard, imageSizes: [.s1K],
        sendsImageConfig: true, highFidelityInputLimit: 14),
      role: .optional(enabledByDefault: true)),
    ModelDescriptor(
      id: "gemini-2.5-flash-image", displayName: "Gemini 2.5 Flash Image", shortName: "2.5 Flash",
      capability: ModelCapability(
        aspectRatios: AspectRatio.standard, imageSizes: [],
        sendsImageConfig: true, highFidelityInputLimit: 3),
      role: .optional(enabledByDefault: true)),
    ModelDescriptor(
      id: "gemini-3-pro-image-preview", displayName: "Gemini 3 Pro Image (preview)",
      shortName: "3 Pro (preview)",
      capability: proCapability, role: .legacyIfListed),
  ]

  static let builtInIDs: Set<String> = Set(builtIns.map(\.id))

  static let customCapability = ModelCapability(
    aspectRatios: AspectRatio.allCases, imageSizes: [.s1K, .s2K, .s4K],
    sendsImageConfig: true, highFidelityInputLimit: 14)

  /// The built-in descriptor, or a custom one with unknown-model capabilities.
  static func descriptor(for id: String) -> ModelDescriptor {
    if let builtIn = builtIns.first(where: { $0.id == id }) { return builtIn }
    return ModelDescriptor(
      id: id, displayName: id, shortName: id, capability: customCapability, role: .custom)
  }
}
