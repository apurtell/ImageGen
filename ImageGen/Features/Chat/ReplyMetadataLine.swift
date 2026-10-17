import SwiftUI

/// Displays compact summary metadata for completed generation requests, including model
/// identifier, target aspect ratio, dimension class, and actual output resolution, appending
/// visual warning badges whenever the backend departs from requested dimension constraints.
struct ReplyMetadataLine: View {
  let request: GenerationRequest

  /// Computes formatted metadata components and discrepancy warnings from generation parameters
  /// and output dimensions independently of SwiftUI view hierarchy lifecycles.
  static func text(modelID: String, aspect: String?, size: String?, width: Int?, height: Int?) -> (line: String, warnings: [String]) {
    var parts = [ModelCatalog.descriptor(for: modelID).shortName]
    if let aspect { parts.append(aspect) }
    if let size { parts.append(size) }
    var warnings: [String] = []
    if let w = width, let h = height {
      parts.append("\(w)×\(h)")
      if let size = size.flatMap(ImageSize.init(rawValue:)), !SizeClass.isSizeHonored(requested: size, width: w, height: h) {
        warnings.append("returned \(SizeClass.classify(width: w, height: h).rawValue)")
      }
      if let aspect = aspect.flatMap(AspectRatio.init(rawValue:)), !SizeClass.isAspectHonored(requested: aspect, width: w, height: h) {
        warnings.append("returned \(SizeClass.nearestAspect(width: w, height: h).rawValue)")
      }
    }
    return (parts.joined(separator: " · "), warnings)
  }

  var body: some View {
    let t = Self.text(
      modelID: request.modelID, aspect: request.aspectRatio, size: request.imageSize, width: request.outputWidth,
      height: request.outputHeight)
    HStack(spacing: 6) {
      Text(t.line)
      ForEach(t.warnings, id: \.self) { w in
        Label(w, systemImage: "exclamationmark.triangle.fill")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(.orange)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
