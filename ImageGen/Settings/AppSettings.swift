import Foundation
import Observation

/// What `models.list` said about each model, and when (D§2.5). Read and written by M8.
struct ModelAvailabilityCache: Codable, Sendable, Equatable {
  /// Model ID → supports `generateContent`.
  var models: [String: Bool]
  var checkedAt: Date
}

/// App-wide settings, persisted in an injectable `UserDefaults`. Actors read a snapshot through
/// `readDefaults(_:)` and never write defaults (D§5).
@Observable @MainActor
final class AppSettings {
  enum Key {
    static let defaultAspectRatio = "settings.defaultAspectRatio"
    static let defaultImageSize = "settings.defaultImageSize"
    static let safetyThreshold = "settings.safetyThreshold"
    static let maxUploadLongEdge = "settings.maxUploadLongEdge"
    static let includeTextModality = "settings.includeTextModality"
    static let omitCivicIntegrity = "settings.omitCivicIntegrity"
    static let disabledCatalogModelIDs = "settings.disabledCatalogModelIDs"
    static let customModelIDs = "settings.customModelIDs"
    static let notifyOnBackgroundCompletion = "settings.notifyOnBackgroundCompletion"
    static let modelAvailabilityCache = "settings.modelAvailabilityCache"
  }

  nonisolated static let allowedLongEdges = [1536, 2048, 3072, 4096]
  /// Until M9 task 8 settles R3 (D§2.4).
  nonisolated static let includeTextModalityDefault = true

  @ObservationIgnored private let defaults: UserDefaults

  var defaultAspectRatio: AspectRatio { didSet { defaults.set(defaultAspectRatio.rawValue, forKey: Key.defaultAspectRatio) } }
  var defaultImageSize: ImageSize { didSet { defaults.set(defaultImageSize.rawValue, forKey: Key.defaultImageSize) } }
  var safetyThreshold: SafetyThreshold { didSet { defaults.set(safetyThreshold.rawValue, forKey: Key.safetyThreshold) } }
  /// 1536, 2048, 3072 or 4096; any other value is treated as 2048.
  var maxUploadLongEdge: Int {
    didSet { defaults.set(Self.validLongEdge(maxUploadLongEdge), forKey: Key.maxUploadLongEdge) }
  }
  var includeTextModality: Bool { didSet { defaults.set(includeTextModality, forKey: Key.includeTextModality) } }
  var omitCivicIntegrity: Bool { didSet { defaults.set(omitCivicIntegrity, forKey: Key.omitCivicIntegrity) } }
  /// Stored as the catalog models turned off, so a model added to the catalog later starts enabled.
  private var disabledCatalogModelIDs: Set<String> {
    didSet { defaults.set(disabledCatalogModelIDs.sorted(), forKey: Key.disabledCatalogModelIDs) }
  }
  var customModelIDs: [String] { didSet { defaults.set(customModelIDs, forKey: Key.customModelIDs) } }
  var notifyOnBackgroundCompletion: Bool {
    didSet { defaults.set(notifyOnBackgroundCompletion, forKey: Key.notifyOnBackgroundCompletion) }
  }
  var modelAvailabilityCache: ModelAvailabilityCache? {
    didSet {
      if let cache = modelAvailabilityCache, let data = try? JSONEncoder().encode(cache) {
        defaults.set(data, forKey: Key.modelAvailabilityCache)
      } else {
        defaults.removeObject(forKey: Key.modelAvailabilityCache)
      }
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let d = Self.readDefaults(defaults)
    defaultAspectRatio = d.aspectRatio
    defaultImageSize = d.imageSize
    safetyThreshold = d.threshold
    maxUploadLongEdge = d.maxUploadLongEdge
    includeTextModality = d.includeTextModality
    omitCivicIntegrity = d.omitCivicIntegrity
    disabledCatalogModelIDs = Self.readDisabled(defaults)
    customModelIDs = defaults.stringArray(forKey: Key.customModelIDs) ?? []
    notifyOnBackgroundCompletion = defaults.object(forKey: Key.notifyOnBackgroundCompletion) as? Bool ?? true
    modelAvailabilityCache = defaults.data(forKey: Key.modelAvailabilityCache)
      .flatMap { try? JSONDecoder().decode(ModelAvailabilityCache.self, from: $0) }
  }

  /// The enabled catalog models plus the custom IDs; always includes Flash, which can't be disabled.
  var enabledModelIDs: Set<String> {
    get { ModelCatalog.builtInIDs.subtracting(disabledCatalogModelIDs).union(customModelIDs) }
    set {
      disabledCatalogModelIDs = ModelCatalog.builtInIDs.subtracting(newValue).subtracting([ModelCatalog.defaultModelID])
    }
  }

  func setModel(_ id: String, enabled: Bool) {
    guard ModelCatalog.builtInIDs.contains(id), id != ModelCatalog.defaultModelID else { return }
    if enabled { disabledCatalogModelIDs.remove(id) } else { disabledCatalogModelIDs.insert(id) }
  }

  func generationDefaults() -> GenerationDefaults {
    GenerationDefaults(
      aspectRatio: defaultAspectRatio, imageSize: defaultImageSize, threshold: safetyThreshold,
      omitCivicIntegrity: omitCivicIntegrity, includeTextModality: includeTextModality,
      enabledModelIDs: enabledModelIDs, maxUploadLongEdge: Self.validLongEdge(maxUploadLongEdge))
  }

  /// The same snapshot, read straight from `UserDefaults` without the main actor.
  nonisolated static func readDefaults(_ ud: UserDefaults) -> GenerationDefaults {
    let edge = ud.object(forKey: Key.maxUploadLongEdge) as? Int
    let custom = ud.stringArray(forKey: Key.customModelIDs) ?? []
    return GenerationDefaults(
      aspectRatio: ud.string(forKey: Key.defaultAspectRatio).flatMap(AspectRatio.init(rawValue:)) ?? .r16x9,
      imageSize: ud.string(forKey: Key.defaultImageSize).flatMap(ImageSize.init(rawValue:)) ?? .s2K,
      threshold: ud.string(forKey: Key.safetyThreshold).flatMap(SafetyThreshold.init(rawValue:)) ?? .blockNone,
      omitCivicIntegrity: ud.object(forKey: Key.omitCivicIntegrity) as? Bool ?? false,
      includeTextModality: ud.object(forKey: Key.includeTextModality) as? Bool ?? includeTextModalityDefault,
      enabledModelIDs: ModelCatalog.builtInIDs.subtracting(readDisabled(ud)).union(custom),
      maxUploadLongEdge: validLongEdge(edge ?? 2048))
  }

  nonisolated static func validLongEdge(_ edge: Int) -> Int {
    allowedLongEdges.contains(edge) ? edge : 2048
  }

  nonisolated private static func readDisabled(_ ud: UserDefaults) -> Set<String> {
    Set(ud.stringArray(forKey: Key.disabledCatalogModelIDs) ?? []).subtracting([ModelCatalog.defaultModelID])
  }
}
