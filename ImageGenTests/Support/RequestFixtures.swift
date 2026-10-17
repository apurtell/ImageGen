import Foundation
import Testing

@testable import ImageGen

/// Shared fixture helpers and assertions for Gemini request payload construction suites.
enum RequestFixtures {
  static let flash = ModelCatalog.defaultModelID
  static let lighthouse = "a lighthouse at dusk"

  static func settings(
    model: String = flash, aspect: AspectRatio? = .r16x9, size: ImageSize? = .s2K,
    threshold: SafetyThreshold = .blockNone, categories: [HarmCategory] = HarmCategory.allCases,
    includeText: Bool = true
  ) -> EffectiveSettings {
    EffectiveSettings(
      modelID: model, aspectRatio: aspect, imageSize: size, threshold: threshold,
      categories: categories, includeTextModality: includeText, coercions: [])
  }

  /// Resolves a static test fixture image from `Fixtures/Images/` as a `BodyImage`.
  static func image(_ name: String) throws -> BodyImage {
    let url = try FixtureLoader.url("Images/\(name)")
    let ext = url.pathExtension
    return BodyImage(
      fileURL: url, mimeType: MimeTypes.mimeType(forExtension: ext) ?? "application/octet-stream",
      byteCount: try FixtureLoader.data("Images/\(name)").count)
  }

  /// Serializes a request specification to disk in the temporary root and reads back the resulting bytes.
  static func write(_ spec: RequestBodySpec, root: TestFileRoot) async throws -> Data {
    let url = root.file("Requests/\(UUID().uuidString)/body.json")
    let written = try await RequestBodyWriter.write(spec, to: url)
    let data = try Data(contentsOf: url)
    #expect(written == data.count)
    return data
  }

  /// Loads a golden JSON fixture from `Fixtures/Requests/`, dynamically substituting `<b64:NAME>` tokens with base64 fixture data.
  static func golden(_ name: String) throws -> Any {
    var text = try FixtureLoader.string("Requests/\(name).json")
    let regex = try NSRegularExpression(pattern: "<b64:([^>]+)>")
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
      let file = ns.substring(with: match.range(at: 1))
      let b64 = try FixtureLoader.data("Images/\(file)").base64EncodedString()
      text = (text as NSString).replacingCharacters(in: match.range, with: b64)
    }
    return try JSONSerialization.jsonObject(with: Data(text.utf8))
  }

  static func json(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data)
  }

  /// Evaluates deep structural equivalence across JSON object hierarchies, ignoring dictionary key ordering.
  static func same(_ a: Any, _ b: Any) -> Bool {
    (a as? NSObject)?.isEqual(b) ?? false
  }

  static func pretty(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
  }
}
