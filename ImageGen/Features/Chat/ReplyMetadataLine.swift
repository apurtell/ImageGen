import SwiftUI

/// `3.1 Flash · 16:9 · 2K · 2752×1536`, with ⚠︎ when the size class or ratio isn't what was asked
/// for (D§3.4, R3 and R4).
///
/// This line is how the app checks reports R3 and R4: the requested values come from the request
/// record, the pixel size from the first output image. `SizeClass` judges the size by pixel count.
struct ReplyMetadataLine: View {
  let request: GenerationRequest

  /// The line and its warnings, as plain values, so tests can check them without a view.
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
