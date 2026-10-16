import Foundation

/// Resolves the settings a request is sent with (D§2.5): the chat's overrides over the global
/// defaults, coerced to what the model supports. Pure; the caller logs any coercions.
enum GenerationSettingsResolver {
  static func resolve(
    _ o: ChatOverrides, _ d: GenerationDefaults,
    catalog: (String) -> ModelDescriptor = ModelCatalog.descriptor(for:)
  ) -> EffectiveSettings {
    var coercions: [Coercion] = []

    // 1. Model: the override only while it's still enabled; Flash can't be disabled.
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

    // 2–3. Aspect ratio and size: override, else the default.
    let requestedAspect = o.aspectRatio ?? d.aspectRatio
    let requestedSize = o.imageSize ?? d.imageSize

    // 4. Coerce to the model's capability.
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

  /// 16:9 if supported, else 1:1, else the first supported ratio.
  private static func coercedAspect(_ supported: [AspectRatio]) -> AspectRatio? {
    if supported.contains(.r16x9) { return .r16x9 }
    if supported.contains(.r1x1) { return .r1x1 }
    return supported.first
  }

  /// The nearest supported size, preferring the larger on a tie.
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
