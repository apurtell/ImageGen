import Foundation

// Shared vocabulary for the Gemini wire format (D§2.4, D§2.5). Raw values are the exact API strings.
//
// Every layer uses these types: the screens show them, the database stores them, and the request
// body sends them. Swift note: `enum Name: String` gives each case a *raw value*, here the API
// string. `Codable` stores a case as that string, and `Name(rawValue:)` reads one back, or returns
// nil for an unknown string. So a stored value and the value on the wire are always the same text.
//
// Coercion: `GenerationSettingsResolver` (in `Pipeline/`) changes a requested aspect ratio or size to
// one the model supports, from the `ModelCapability` table below (D§2.5). These types only describe
// the values; they do not coerce.
//
// Everything here is an immutable value or a static constant, so all of it is `Sendable` and needs
// no lock.

/// The four sections of the composer's aspect-ratio menu (D§3.5).
enum AspectGroup: String, Sendable, Codable, CaseIterable {
  case landscape, square, portrait, extreme
}

/// All 14 aspect ratios the API accepts. The case names start with `r` because a Swift name cannot
/// start with a digit. `CaseIterable` gives `allCases`, in declaration order.
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

  /// Width divided by height. `SizeClass` (in `Imaging/`) uses it to check an output image's shape.
  /// The raw values are fixed `W:H` strings, so the two sides always exist.
  var ratio: Double {
    let sides = rawValue.split(separator: ":").compactMap { Double($0) }
    return sides[0] / sides[1]
  }

  /// The 10 standard ratios: all 14 without 1:4, 4:1, 1:8 and 8:1 (D§2.5).
  static let standard: [AspectRatio] = allCases.filter { $0.group != .extreme }
}

/// The output size class. The raw values are the exact API strings: `"512"` (never `"512px"`), and
/// `K` in uppercase (D§2.4).
///
/// Declaration order matters: it is smallest to largest. `GenerationSettingsResolver` uses the order
/// of `allCases` to find the nearest supported size.
enum ImageSize: String, Sendable, Codable, CaseIterable {
  case s512 = "512"
  case s1K = "1K"
  case s2K = "2K"
  case s4K = "4K"

  /// The expected pixel count, in millions. `SizeClass` compares an output image with it to find the
  /// size class that the model actually returned.
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

/// The pipe's threshold set (D§2.4). The API also has `OFF`, which the app does not offer.
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

/// In the pipe's order, which is also the wire order. Array order in the body is significant, so do not
/// reorder the cases. `civicIntegrity` is deprecated in the API; the app sends it and falls back once
/// without it when the API rejects it (D§2.4).
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

/// The life cycle of one request (D§4.3, D§4.6). The database stores the raw value.
///
/// A *live* state means that the pipeline still owns the request and can change it. A *terminal* state
/// is final: the pipeline does not change it again, and the Janitor can clean up the request's folder.
/// The `switch` statements list every case with no `default`, so a new case does not compile until it
/// is put in one group.
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

/// What one model accepts (D§2.5). `GenerationSettingsResolver` coerces the settings to it, and the
/// composer menus show only these values.
struct ModelCapability: Sendable, Equatable {
  var aspectRatios: [AspectRatio]
  /// Empty means the `imageSize` key is omitted.
  var imageSizes: [ImageSize]
  /// False means the body has no `imageConfig` at all. Every catalog model sends it today.
  var sendsImageConfig: Bool
  /// Soft tray-warning threshold (D§2.5); 14 means no soft warning.
  var highFidelityInputLimit: Int
}

/// One model as the app shows and uses it: a catalog entry or a custom ID.
struct ModelDescriptor: Sendable, Equatable, Identifiable {
  /// How Settings and the model menu treat the model (D§2.5).
  enum Role: Sendable, Equatable {
    /// Flash: always enabled, and the fallback for any model that is not available.
    case defaultMandatory
    /// The user can turn it off in Settings › Models.
    case optional(enabledByDefault: Bool)
    /// The preview alias: offered only after `models.list` lists it.
    case legacyIfListed
    /// An ID the user typed. Its capabilities are unknown, so it gets `customCapability`.
    case custom
  }

  var id: String
  var displayName: String
  var shortName: String
  var capability: ModelCapability
  var role: Role
}

/// The static table of known models (D§2.5). A model's availability for a key is a separate,
/// runtime check (`ModelAvailabilityService`); this table only says what each model accepts.
enum ModelCatalog {
  static let defaultModelID = "gemini-3.1-flash-image"

  /// Shared by 3 Pro and its preview alias. 5 is the lower of the two documented input limits.
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

  /// For an unknown model: every ratio and every size but 512, and no soft input warning (14 is the
  /// hard cap). An API error for an unsupported value is shown as the API returns it.
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
