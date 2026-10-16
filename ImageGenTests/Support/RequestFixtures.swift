import Foundation
import Testing

@testable import ImageGen

/// Helpers shared by the request-building suites (plan §2.3).
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

  /// A checked-in image from `Fixtures/Images/`.
  static func image(_ name: String) throws -> BodyImage {
    let url = try FixtureLoader.url("Images/\(name)")
    let ext = url.pathExtension
    return BodyImage(
      fileURL: url, mimeType: MimeTypes.mimeType(forExtension: ext) ?? "application/octet-stream",
      byteCount: try FixtureLoader.data("Images/\(name)").count)
  }

  /// Writes the body to a file under `root` and returns its bytes.
  static func write(_ spec: RequestBodySpec, root: TestFileRoot) async throws -> Data {
    let url = root.file("Requests/\(UUID().uuidString)/body.json")
    let written = try await RequestBodyWriter.write(spec, to: url)
    let data = try Data(contentsOf: url)
    #expect(written == data.count)
    return data
  }

  /// A golden from `Fixtures/Requests/` with each `"<b64:NAME>"` token expanded from `Fixtures/Images/`.
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

  /// Structural equality: key order ignored, array order kept.
  static func same(_ a: Any, _ b: Any) -> Bool {
    (a as? NSObject)?.isEqual(b) ?? false
  }

  static func pretty(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
  }
}
