import Foundation

/// Descriptor representing a prepared image asset to be incorporated into the JSON upload payload.
struct BodyImage: Sendable {
  let fileURL: URL
  let mimeType: String
  /// Stated byte length of the prepared image file on disk.
  let byteCount: Int
}

/// Input parameters defining the generation request payload.
struct RequestBodySpec: Sendable {
  let images: [BodyImage]
  let promptText: String?
  let settings: EffectiveSettings
}

/// Errors raised during request body envelope composition and streaming serialization.
enum RequestBodyError: Error, Equatable {
  /// Payload contains neither text prompts nor multimodal image attachments.
  case emptyParts
  /// Actual image file size on disk diverged from the measured length in the specification.
  case imageSizeMismatch(index: Int, expected: Int, actual: Int)
}

/// Streams `generateContent` JSON request bodies directly to persistent disk storage.
/// To support large multimodal payloads without excessive resident memory consumption, the JSON envelope
/// structure is composed using placeholders and emitted in interleaved chunks alongside incremental 48 KiB base64
/// streams of each referenced image file.
enum RequestBodyWriter {
  /// Chunk buffer size (48 KiB). Selected as a multiple of 3 to align base64 encoding boundaries across intermediate chunks.
  static let chunkSize = 49_152

  /// Calculates the exact byte length of the resulting JSON payload without performing disk read operations.
  static func predictedSize(_ spec: RequestBodySpec) throws -> Int {
    let envelope = try Envelope(spec)
    return envelope.segments.reduce(0) { $0 + $1.count }
      + spec.images.reduce(0) { $0 + base64Length($1.byteCount) }
  }

  /// Streams the serialized JSON request body to `url` on a background concurrency thread.
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

  /// Computes padded base64 output length for a given raw byte count (`4 * ceil(n / 3)`).
  static func base64Length(_ n: Int) -> Int { 4 * ((n + 2) / 3) }

  /// Represents pre-encoded JSON segments partitioned around base64 payload insertion points.
  private struct Envelope {
    let segments: [Data]

    init(_ spec: RequestBodySpec) throws {
      let text = spec.promptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !spec.images.isEmpty || !text.isEmpty else { throw RequestBodyError.emptyParts }

      // Generate unique boundary tokens to safely delimit base64 insertion points within serialized JSON.
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

      // Enforce deterministic byte serialization to ensure predicted size calculations match streamed output.
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

  /// Polymorphic part entry serializing either inline image data or user text prompts.
  private enum WirePart: Encodable {
    /// The MIME type and the placeholder that stands for the base64 data.
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

  /// One entry per category, all at the same threshold, in the order of `settings.categories`.
  private struct WireSafety: Encodable {
    let category: String
    let threshold: String
  }
}
