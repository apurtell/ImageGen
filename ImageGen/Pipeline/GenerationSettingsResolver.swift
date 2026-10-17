import Foundation

/// Resolves effective generation settings by layering conversation specific overrides on top of
/// global application defaults and coercing parameters to match target model capabilities.
/// Stateless utility namespace evaluated during UI configuration updates and draft submission.
enum GenerationSettingsResolver {
  static func resolve(
    _ o: ChatOverrides, _ d: GenerationDefaults,
    catalog: (String) -> ModelDescriptor = ModelCatalog.descriptor(for:)
  ) -> EffectiveSettings {
    var coercions: [Coercion] = []

    // Validate requested model identifier against enabled models. Fallback to default model if unavailable.
    var modelID = ModelCatalog.defaultModelID
    if let requested = o.modelID {
      if requested == ModelCatalog.defaultModelID || d.enabledModelIDs.contains(requested) {
        modelID = requested
      } else {
        coercions.append(
          Coercion(
            field: .model, requested: requested, used: modelID,
            reason: "model is disabled or was removed in Settings"))
      }
    }
    let capability = catalog(modelID).capability

    // Resolve aspect ratio and image resolution from overrides with fallback to global defaults.
    let requestedAspect = o.aspectRatio ?? d.aspectRatio
    let requestedSize = o.imageSize ?? d.imageSize

    // Coerce dimensions and parameters to model capability constraints.
    var aspect: AspectRatio? = requestedAspect
    var size: ImageSize? = requestedSize
    if !capability.sendsImageConfig {
      aspect = nil
      size = nil
      coercions.append(
        Coercion(field: .aspectRatio, requested: requestedAspect.rawValue, used: nil, reason: "model takes no image settings"))
      coercions.append(
        Coercion(field: .imageSize, requested: requestedSize.rawValue, used: nil, reason: "model takes no image settings"))
    } else {
      if !capability.aspectRatios.contains(requestedAspect) {
        let used = coercedAspect(capability.aspectRatios)
        aspect = used
        coercions.append(
          Coercion(
            field: .aspectRatio, requested: requestedAspect.rawValue, used: used?.rawValue,
            reason: "\(requestedAspect.rawValue) isn't supported by this model"))
      }
      if capability.imageSizes.isEmpty {
        size = nil
        coercions.append(
          Coercion(
            field: .imageSize, requested: requestedSize.rawValue, used: nil,
            reason: "model has a fixed output size"))
      } else if !capability.imageSizes.contains(requestedSize) {
        let used = nearestSize(to: requestedSize, in: capability.imageSizes)
        size = used
        coercions.append(
          Coercion(
            field: .imageSize, requested: requestedSize.rawValue, used: used.rawValue,
            reason: "\(requestedSize.rawValue) isn't supported by this model"))
      }
    }

    return EffectiveSettings(
      modelID: modelID, aspectRatio: aspect, imageSize: size, threshold: d.threshold,
      categories: d.omitCivicIntegrity
        ? HarmCategory.allCases.filter { $0 != .civicIntegrity } : HarmCategory.allCases,
      includeTextModality: d.includeTextModality, coercions: coercions)
  }

  /// Selects the closest standard fallback aspect ratio supported by the model, preferring 16:9, then 1:1.
  private static func coercedAspect(_ supported: [AspectRatio]) -> AspectRatio? {
    if supported.contains(.r16x9) { return .r16x9 }
    if supported.contains(.r1x1) { return .r1x1 }
    return supported.first
  }

  /// Selects the nearest supported output resolution from discrete supported sizes, breaking ties toward higher resolution.
  private static func nearestSize(to requested: ImageSize, in supported: [ImageSize]) -> ImageSize {
    let order = ImageSize.allCases
    let target = order.firstIndex(of: requested)!
    return supported.min { a, b in
      let da = abs(order.firstIndex(of: a)! - target)
      let db = abs(order.firstIndex(of: b)! - target)
      return da != db ? da < db : order.firstIndex(of: a)! > order.firstIndex(of: b)!
    }!
  }
}
