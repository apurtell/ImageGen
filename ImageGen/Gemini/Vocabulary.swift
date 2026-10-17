import Foundation

/// Vocabulary definitions and serialization primitives for wire protocols.
///
/// Raw values align exactly with upstream API literals. These domain types are shared uniformly
/// across presentation models, persistence entities, and networking serializers. Constraint validation
/// and capability coercion (such as aspect ratio fallback) are handled upstream in `GenerationSettingsResolver`.
/// All definitions are value types or immutable static descriptors, satisfying `Sendable` concurrency contracts.

/// Aspect ratio category groupings utilized for composer layout organization.
enum AspectGroup: String, Sendable, Codable, CaseIterable {
  case landscape, square, portrait, extreme
}

/// Permissible aspect ratios defined by the Gemini generative imaging protocol.
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

  /// The structural aspect group for visual categorization and presentation filters.
  var group: AspectGroup {
    switch self {
    case .r16x9, .r21x9, .r3x2, .r4x3, .r5x4: .landscape
    case .r1x1: .square
    case .r9x16, .r2x3, .r3x4, .r4x5: .portrait
    case .r4x1, .r8x1, .r1x4, .r1x8: .extreme
    }
  }

  /// Numeric representation computed as width divided by height, utilized for geometric tolerance matching.
  var ratio: Double {
    let sides = rawValue.split(separator: ":").compactMap { Double($0) }
    return sides[0] / sides[1]
  }

  /// Standard aspect ratio options, excluding extreme panoramic ratios (1:4, 4:1, 1:8, 8:1).
  static let standard: [AspectRatio] = allCases.filter { $0.group != .extreme }
}

/// Output resolution tiers recognized by the Gemini generative endpoints.
/// Declared in ascending order of spatial resolution to support nearest-supported tier resolution.
enum ImageSize: String, Sendable, Codable, CaseIterable {
  case s512 = "512"
  case s1K = "1K"
  case s2K = "2K"
  case s4K = "4K"

  /// Nominal megapixel resolution used by imaging diagnostics to classify generated output dimensions.
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

/// Content moderation sensitivity thresholds mapping directly to API safety filter directives.
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

/// Harm categories evaluated by safety classifiers, maintained in canonical wire sequence.
enum HarmCategory: String, Sendable, Codable, CaseIterable {
  case harassment = "HARM_CATEGORY_HARASSMENT"
  case hateSpeech = "HARM_CATEGORY_HATE_SPEECH"
  case sexuallyExplicit = "HARM_CATEGORY_SEXUALLY_EXPLICIT"
  case dangerousContent = "HARM_CATEGORY_DANGEROUS_CONTENT"
  case civicIntegrity = "HARM_CATEGORY_CIVIC_INTEGRITY"
}

/// Attribution metadata capturing the resolution strategy for multi-modal reference image inclusion.
enum SelectionReason: String, Sendable, Codable, CaseIterable {
  case attachments
  case pinned
  case latest
  case noImage = "none"
}

/// Lifecycle states governing generation request progression from preparation to completion.
///
/// States are partitioned into active/live transitions (where the execution pipeline retains ownership)
/// and immutable terminal states (enabling cache reclamation and archival storage).
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

/// Feature specification and parameter boundaries supported by a designated foundation model.
struct ModelCapability: Sendable, Equatable {
  var aspectRatios: [AspectRatio]
  /// Allowed image size tiers; an empty array denotes that the model omits the `imageSize` parameter.
  var imageSizes: [ImageSize]
  /// Indicates whether the endpoint accepts the top-level `imageConfig` payload container.
  var sendsImageConfig: Bool
  /// High-fidelity input reference quota triggering client-side advisories.
  var highFidelityInputLimit: Int
}

/// Model definition metadata combining service identifiers, display strings, and operational capabilities.
struct ModelDescriptor: Sendable, Equatable, Identifiable {
  /// Operational role and availability policies governing UI visibility and fallbacks.
  enum Role: Sendable, Equatable {
    /// Baseline default model; unconditionally enabled and acts as execution fallback.
    case defaultMandatory
    /// User-configurable model enabled or disabled via Settings preferences.
    case optional(enabledByDefault: Bool)
    /// Experimental or preview variant exposed conditionally upon discovery in model listings.
    case legacyIfListed
    /// Arbitrary user-specified model identifier operating under conservative default capabilities.
    case custom
  }

  var id: String
  var displayName: String
  var shortName: String
  var capability: ModelCapability
  var role: Role
}

/// Static catalog indexing known Gemini model variants and their hardware/pipeline capabilities.
enum ModelCatalog {
  static let defaultModelID = "gemini-3.1-flash-image"

  /// Shared baseline capability profile for Pro model tiers.
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

  /// Default capability configuration applied to unrecognized custom model identifiers.
  static let customCapability = ModelCapability(
    aspectRatios: AspectRatio.allCases, imageSizes: [.s1K, .s2K, .s4K],
    sendsImageConfig: true, highFidelityInputLimit: 14)

  /// Resolves a model descriptor from catalog records, synthesising a custom descriptor for unknown IDs.
  static func descriptor(for id: String) -> ModelDescriptor {
    if let builtIn = builtIns.first(where: { $0.id == id }) { return builtIn }
    return ModelDescriptor(
      id: id, displayName: id, shortName: id, capability: customCapability, role: .custom)
  }
}
