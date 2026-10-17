import Foundation
import Observation

/// What `models.list` said about each model, and when (D§2.5). Read and written by M8.
/// Stored in `UserDefaults` as JSON (`Codable` makes the struct encodable).
struct ModelAvailabilityCache: Codable, Sendable, Equatable {
  /// Model ID → supports `generateContent`.
  var models: [String: Bool]
  var checkedAt: Date
}

/// App-wide settings, persisted in an injectable `UserDefaults`. Actors read a snapshot through
/// `readDefaults(_:)` and never write defaults (D§5).
///
/// `UserDefaults` is the operating system's small key-value store for preferences. This class keeps a
/// copy of each setting in a property, for the Settings sheet and the chat screens. Each property's
/// `didSet` writes the new value back to `UserDefaults` at once. `@Observable` makes SwiftUI redraw the
/// views that read a property when it changes (see the primer, *SwiftUI: the user interface*).
///
/// Concurrency: the class is `@MainActor`, so only main-actor code reads or writes the properties.
/// Code on other actors (`GenerationService`, `NotificationPoster`) uses the `nonisolated static` readers
/// below, which read `UserDefaults` directly. When the service must change a setting (the CIVIC
/// fallback), it hops to the main actor and sets the property, so this copy is never stale (D§5).
@Observable @MainActor
final class AppSettings {
  /// The `UserDefaults` keys. The instance properties and the static readers use the same keys.
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

  // `nonisolated` on constants: code off the main actor can read them without an `await`.
  nonisolated static let allowedLongEdges = [1536, 2048, 3072, 4096]
  /// Until M9 task 8 settles R3 (D§2.4).
  /// R3 is now settled (D§2.4, revision notes): the default stays `true`, so requests ask for TEXT and IMAGE.
  nonisolated static let includeTextModalityDefault = true

  @ObservationIgnored private let defaults: UserDefaults

  // `didSet` runs after each assignment and saves the value. It does not run for the assignments in
  // `init`, so loading the settings does not write them back.
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
  /// nil removes the stored cache.
  var modelAvailabilityCache: ModelAvailabilityCache? {
    didSet {
      if let cache = modelAvailabilityCache, let data = try? JSONEncoder().encode(cache) {  // Encoding a plain struct does not fail.
        defaults.set(data, forKey: Key.modelAvailabilityCache)
      } else {
        defaults.removeObject(forKey: Key.modelAvailabilityCache)
      }
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // The same reader as the actors use, so both sides apply the same fallbacks to a missing value.
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
      .flatMap { try? JSONDecoder().decode(ModelAvailabilityCache.self, from: $0) }  // A cache in an old format counts as none.
  }

  /// The enabled catalog models plus the custom IDs; always includes Flash, which can't be disabled.
  /// The setter stores the complement (the disabled catalog models), and never disables Flash.
  var enabledModelIDs: Set<String> {
    get { ModelCatalog.builtInIDs.subtracting(disabledCatalogModelIDs).union(customModelIDs) }
    set {
      disabledCatalogModelIDs = ModelCatalog.builtInIDs.subtracting(newValue).subtracting([ModelCatalog.defaultModelID])
    }
  }

  /// Turns one catalog model on or off. Custom IDs and Flash are ignored.
  func setModel(_ id: String, enabled: Bool) {
    guard ModelCatalog.builtInIDs.contains(id), id != ModelCatalog.defaultModelID else { return }
    if enabled { disabledCatalogModelIDs.remove(id) } else { disabledCatalogModelIDs.insert(id) }
  }

  /// A `Sendable` snapshot of the generation settings, for a send from the main actor.
  func generationDefaults() -> GenerationDefaults {
    GenerationDefaults(
      aspectRatio: defaultAspectRatio, imageSize: defaultImageSize, threshold: safetyThreshold,
      omitCivicIntegrity: omitCivicIntegrity, includeTextModality: includeTextModality,
      enabledModelIDs: enabledModelIDs, maxUploadLongEdge: Self.validLongEdge(maxUploadLongEdge))
  }

  /// The same snapshot, read straight from `UserDefaults` without the main actor.
  /// `GenerationService` uses it for Regenerate and Retry rebuilds. `UserDefaults` is safe to read from
  /// any thread. Each missing or unknown value falls back to its default here.
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

  /// The Settings toggle for notifications, read off the main actor by `NotificationPoster`.
  /// A missing value means on.
  nonisolated static func readNotifyOnBackgroundCompletion(_ ud: UserDefaults) -> Bool {
    ud.object(forKey: Key.notifyOnBackgroundCompletion) as? Bool ?? true
  }

  nonisolated static func validLongEdge(_ edge: Int) -> Int {
    allowedLongEdges.contains(edge) ? edge : 2048
  }

  /// The stored disabled set, without Flash even if an old value lists it.
  nonisolated private static func readDisabled(_ ud: UserDefaults) -> Set<String> {
    Set(ud.stringArray(forKey: Key.disabledCatalogModelIDs) ?? []).subtracting([ModelCatalog.defaultModelID])
  }
}
