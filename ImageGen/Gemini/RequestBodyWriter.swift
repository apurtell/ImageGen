import Foundation

/// One input image for the body: a prepared file on disk (D§4.8), never bytes in memory.
struct BodyImage: Sendable {
  let fileURL: URL
  let mimeType: String
  /// The file's size in bytes. The writer checks it, because the predicted body size depends on it.
  let byteCount: Int
}

/// Everything the body depends on. The same spec gives the same body, apart from the placeholder nonce,
/// which never reaches the output.
struct RequestBodySpec: Sendable {
  let images: [BodyImage]
  let promptText: String?
  let settings: EffectiveSettings
}

/// Swift note: an `enum` case can carry values (here, the index and the two sizes). See the primer,
/// *Enum with associated values*.
enum RequestBodyError: Error, Equatable {
  /// No images and no text (D§2.2).
  case emptyParts
  /// An image file's size no longer matches its `byteCount`, so the predicted size would be wrong.
  case imageSizeMismatch(index: Int, expected: Int, actual: Int)
}

/// Streams the `generateContent` body to a file (D§2.4): the JSON envelope comes from
/// `JSONEncoder`, and each image is base64-encoded from its file in 48 KiB reads, so no full body
/// is ever held in memory. Pure apart from the file it writes; it doesn't log.
///
/// Why a file: a request can carry up to 14 images of several MB each. The background `URLSession`
/// uploads only from a file (D§4.6), and a body in memory would cost its full size again as base64.
///
/// The method: the writer encodes the JSON with a unique placeholder string where each image's base64
/// goes. It then splits the encoded bytes at the placeholders into *segments*. To write, it alternates:
/// segment 0, image 0's base64, segment 1, image 1's base64, and so on, then the last segment. So
/// `JSONEncoder` does all the escaping, and no image byte passes through it.
///
/// Callers: `RequestPreparer` (in `Pipeline/`) calls `predictedSize` to plan the size budget, then
/// `write`. The composer calls `predictedSize` to show the size of a body before a send.
///
/// Concurrency: an `enum` with no cases is a namespace for static functions; it has no shared state.
/// Two writes can run at the same time if their output files are different.
enum RequestBodyWriter {
  /// A multiple of 3, so only the last chunk of an image gets base64 padding. Each 3 input bytes
  /// encode to exactly 4 output bytes, so chunks can be encoded one at a time and joined.
  static let chunkSize = 49_152

  /// The exact size of the body that `write` makes, without reading any image file. It is the envelope
  /// bytes plus `4*ceil(n/3)` for each image (D§2.4). A caller that passes `byteCount: 0` for each image
  /// gets the envelope bytes only. Throws `RequestBodyError.emptyParts` for a body with no parts.
  static func predictedSize(_ spec: RequestBodySpec) throws -> Int {
    let envelope = try Envelope(spec)
    return envelope.segments.reduce(0) { $0 + $1.count }
      + spec.images.reduce(0) { $0 + base64Length($1.byteCount) }
  }

  /// Writes the body to `url` and returns the bytes written. The result equals `predictedSize` for
  /// the same spec, or the write throws `imageSizeMismatch`.
  ///
  /// Swift note: `@concurrent` makes this `async` function run away from the caller's actor, on a
  /// background thread. The caller awaits it, and the caller's actor stays free for other work during
  /// the file I/O. See the primer, *Tasks and cancellation*.
  ///
  /// It does not check for cancellation. The caller checks before and after the write.
  @concurrent
  static func write(_ spec: RequestBodySpec, to url: URL) async throws -> Int {
    // The envelope comes first: an empty spec throws here, before any file exists.
    let envelope = try Envelope(spec)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let out = try FileHandle(forWritingTo: url)
    // Swift note: `defer` runs when the scope exits, on every path, including a throw. See the primer,
    // *Errors and early exits*.
    defer { try? out.close() }  // Every write already succeeded or threw.

    var written = 0
    // There is one more segment than images, so the last segment has no image after it.
    for (index, segment) in envelope.segments.enumerated() {
      try out.write(contentsOf: segment)
      written += segment.count
      guard index < spec.images.count else { continue }
      let image = spec.images[index]
      let input = try FileHandle(forReadingFrom: image.fileURL)
      defer { try? input.close() }  // Closing a file that was only read cannot lose data.
      var read = 0
      while true {
        // `autoreleasepool` frees each chunk's temporary Foundation objects at once. Without it, they
        // can stay alive until the whole loop ends, and memory grows with the image size.
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
      // The file changed after it was measured. The upload's Content-Length would then be wrong, so the
      // write fails instead of sending a body with a size that does not match.
      if read != image.byteCount {
        throw RequestBodyError.imageSizeMismatch(index: index, expected: image.byteCount, actual: read)
      }
    }
    return written
  }

  /// The base64 length of `n` bytes, with padding: `4*ceil(n/3)`.
  static func base64Length(_ n: Int) -> Int { 4 * ((n + 2) / 3) }

  // MARK: Envelope

  /// The encoded envelope split around each image's base64 (the quotes stay in the envelope).
  /// `segments.count` is always `images.count + 1`.
  private struct Envelope {
    let segments: [Data]

    init(_ spec: RequestBodySpec) throws {
      let text = spec.promptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !spec.images.isEmpty || !text.isEmpty else { throw RequestBodyError.emptyParts }

      // A random nonce makes each placeholder unique, so a prompt cannot contain one by chance. If it
      // did, the search below could split the envelope at the wrong place.
      let nonce = UUID().uuidString
      let placeholders = spec.images.indices.map { "__IMG_\(nonce)_\($0)__" }
      // Images first, in selection order, then the text last: the pipe's order (D§2.4).
      var parts = zip(spec.images, placeholders).map { WirePart.inline($0.mimeType, $1) }
      if !text.isEmpty { parts.append(.text(text)) }

      // The settings are already coerced to the model's capability (D§2.5). A nil value means "leave
      // the key out"; with both nil, the whole `imageConfig` object is left out.
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

      // Sorted keys make the bytes deterministic, so golden tests and the size prediction are stable
      // (D§2.4). Unescaped slashes keep `image/jpeg` readable; both forms are valid JSON.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let encoded = try encoder.encode(body)

      var segments: [Data] = []
      var start = encoded.startIndex
      // Each placeholder is plain ASCII that the encoder does not escape, and the parts are in order,
      // so each search finds its placeholder after the previous one. The `!` cannot fail.
      for placeholder in placeholders {
        let range = encoded.range(of: Data(placeholder.utf8), in: start..<encoded.endIndex)!
        segments.append(encoded[start..<range.lowerBound])
        start = range.upperBound
      }
      segments.append(encoded[start..<encoded.endIndex])
      self.segments = segments
    }
  }

  // MARK: Wire types
  // These mirror the JSON shape in D§2.4. `Encodable` makes the compiler generate the JSON encoding.

  private struct WireBody: Encodable {
    let contents: [WireContent]
    let generationConfig: WireGenerationConfig
    let safetySettings: [WireSafety]
  }

  private struct WireContent: Encodable {
    let role: String
    let parts: [WirePart]
  }

  /// One entry of `parts`: either `{"inlineData": {...}}` or `{"text": "..."}`. The compiler's generated
  /// encoding for an enum has another shape, so `encode(to:)` writes this one by hand.
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
