import Foundation

struct BodyImage: Sendable {
  let fileURL: URL
  let mimeType: String
  let byteCount: Int
}

struct RequestBodySpec: Sendable {
  let images: [BodyImage]
  let promptText: String?
  let settings: EffectiveSettings
}

enum RequestBodyError: Error, Equatable {
  /// No images and no text (D§2.2).
  case emptyParts
  /// An image file's size no longer matches its `byteCount`, so the predicted size would be wrong.
  case imageSizeMismatch(index: Int, expected: Int, actual: Int)
}

/// Streams the `generateContent` body to a file (D§2.4): the JSON envelope comes from
/// `JSONEncoder`, and each image is base64-encoded from its file in 48 KiB reads, so no full body
/// is ever held in memory. Pure apart from the file it writes; it doesn't log.
enum RequestBodyWriter {
  /// A multiple of 3, so only the last chunk of an image gets base64 padding.
  static let chunkSize = 49_152

  static func predictedSize(_ spec: RequestBodySpec) throws -> Int {
    let envelope = try Envelope(spec)
    return envelope.segments.reduce(0) { $0 + $1.count }
      + spec.images.reduce(0) { $0 + base64Length($1.byteCount) }
  }

  /// Returns the bytes written.
  @concurrent
  static func write(_ spec: RequestBodySpec, to url: URL) async throws -> Int {
    let envelope = try Envelope(spec)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let out = try FileHandle(forWritingTo: url)
    defer { try? out.close() }

    var written = 0
    for (index, segment) in envelope.segments.enumerated() {
      try out.write(contentsOf: segment)
      written += segment.count
      guard index < spec.images.count else { continue }
      let image = spec.images[index]
      let input = try FileHandle(forReadingFrom: image.fileURL)
      defer { try? input.close() }
      var read = 0
      while true {
        let done: Bool = try autoreleasepool {
          guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { return true }
          read += chunk.count
          let encoded = chunk.base64EncodedData()
          try out.write(contentsOf: encoded)
          written += encoded.count
          return false
        }
        if done { break }
      }
      if read != image.byteCount {
        throw RequestBodyError.imageSizeMismatch(index: index, expected: image.byteCount, actual: read)
      }
    }
    return written
  }

  static func base64Length(_ n: Int) -> Int { 4 * ((n + 2) / 3) }

  // MARK: Envelope

  /// The encoded envelope split around each image's base64 (the quotes stay in the envelope).
  private struct Envelope {
    let segments: [Data]

    init(_ spec: RequestBodySpec) throws {
      let text = spec.promptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !spec.images.isEmpty || !text.isEmpty else { throw RequestBodyError.emptyParts }

      let nonce = UUID().uuidString
      let placeholders = spec.images.indices.map { "__IMG_\(nonce)_\($0)__" }
      var parts = zip(spec.images, placeholders).map { WirePart.inline($0.mimeType, $1) }
      if !text.isEmpty { parts.append(.text(text)) }

      let s = spec.settings
      let imageConfig: WireImageConfig? =
        s.aspectRatio == nil && s.imageSize == nil
        ? nil : WireImageConfig(aspectRatio: s.aspectRatio?.rawValue, imageSize: s.imageSize?.rawValue)
      let body = WireBody(
        contents: [WireContent(role: "user", parts: parts)],
        generationConfig: WireGenerationConfig(
          responseModalities: s.includeTextModality ? ["TEXT", "IMAGE"] : ["IMAGE"],
          imageConfig: imageConfig),
        safetySettings: s.categories.map { WireSafety(category: $0.rawValue, threshold: s.threshold.rawValue) })

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let encoded = try encoder.encode(body)

      var segments: [Data] = []
      var start = encoded.startIndex
      for placeholder in placeholders {
        let range = encoded.range(of: Data(placeholder.utf8), in: start..<encoded.endIndex)!
        segments.append(encoded[start..<range.lowerBound])
        start = range.upperBound
      }
      segments.append(encoded[start..<encoded.endIndex])
      self.segments = segments
    }
  }

  private struct WireBody: Encodable {
    let contents: [WireContent]
    let generationConfig: WireGenerationConfig
    let safetySettings: [WireSafety]
  }

  private struct WireContent: Encodable {
    let role: String
    let parts: [WirePart]
  }

  private enum WirePart: Encodable {
    case inline(String, String)
    case text(String)

    private struct InlineData: Encodable {
      let mimeType: String
      let data: String
    }

    private enum Keys: String, CodingKey { case inlineData, text }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Keys.self)
      switch self {
      case .inline(let mime, let placeholder):
        try c.encode(InlineData(mimeType: mime, data: placeholder), forKey: .inlineData)
      case .text(let text):
        try c.encode(text, forKey: .text)
      }
    }
  }

  private struct WireGenerationConfig: Encodable {
    let responseModalities: [String]
    /// Omitted when nil.
    let imageConfig: WireImageConfig?
  }

  /// Each key is omitted when nil.
  private struct WireImageConfig: Encodable {
    let aspectRatio: String?
    let imageSize: String?
  }

  private struct WireSafety: Encodable {
    let category: String
    let threshold: String
  }
}
