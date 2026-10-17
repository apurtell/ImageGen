import Foundation
import ImageIO

/// Represents a decoded output image artifact written directly to disk storage within the request
/// attempt directory, maintaining file references rather than retaining image buffers in memory.
struct StoredOutputImage: Sendable, Equatable {
  let fileURL: URL
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

/// Discretized output blocks constituting a model response candidate, preserved in lexical arrival sequence.
enum OutputPart: Sendable, Equatable {
  case text(String)
  case image(StoredOutputImage)
}

/// The structured outcome resulting from response body parsing for a single execution attempt.
///
/// Encapsulates API errors, policy refusals, malformed payloads, or successful image/text content
/// along with sanitized diagnostic details capped at diagnostic quotas for inspection.
enum ParsedOutcome: Sendable {
  case success(
    parts: [OutputPart], finishReason: String?, notices: [String], modelVersion: String?,
    responseID: String?, details: String)
  /// Refusal by safety filters or prompt feedback policies, preserving raw finish reasons and messages.
  case refused(reason: String, message: String?, notices: [String], details: String)
  case empty(finishReason: String?, details: String)
  /// Upstream HTTP or Google RPC protocol errors.
  case apiError(httpStatus: Int, status: String?, message: String, details: String)
  case malformed(details: String)
}

/// Parses raw Gemini `generateContent` response payload files into strongly typed domain outcomes.
///
/// Execution Architecture:
/// - File-backed parsing maps the response file via `Data(contentsOf:options:.mappedIfSafe)` to avoid
///   large contiguous heap allocations.
/// - Images are extracted, verified via ImageIO metadata headers without full pixel buffer decoding,
///   written directly to distinct artifact files, and subsequently released from memory.
/// - Operates concurrently off the caller's actor context to maintain pipeline responsiveness during
///   decoding and I/O.
enum ResponseParser {
  /// Terminal finish reasons that do not signify a safety refusal when images are absent.
  static let nonRefusingFinishReasons: Set<String> = ["STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED"]

  /// Parses the response payload file and outputs extracted images to the designated destination directory.
  ///
  /// Throws solely upon disk I/O failure when writing extracted image files; upstream protocol errors,
  /// schema violations, or decoding defects are mapped into explicit `ParsedOutcome` variants.
  @concurrent
  static func parse(httpStatus: Int, bodyURL: URL, outputDirectory: URL) async throws -> ParsedOutcome {
    // Memory-map the payload file to optimize resident set size during decoding.
    let body = (try? Data(contentsOf: bodyURL, options: .mappedIfSafe)) ?? Data()

    // 1. Non-2xx HTTP responses: parse structured RPC error details or retain a bounded diagnostic prefix.
    guard (200..<300).contains(httpStatus) else {
      let details = Redactor.details(body)
      if let error = GeminiErrorBody.decode(body) {
        return .apiError(
          httpStatus: httpStatus, status: error.status,
          message: error.message ?? "", details: details)
      }
      let text = Redactor.utf8Prefix(String(decoding: body.prefix(4096), as: UTF8.self), maxBytes: 2048)
      return .apiError(httpStatus: httpStatus, status: nil, message: text, details: details)
    }

    // 2. Decode response structure; syntax or schema failures designate a malformed response.
    guard let response = try? JSONDecoder().decode(GenerateContentResponse.self, from: body) else {
      return .malformed(details: Redactor.details(body))
    }
    let details = Redactor.details(body)

    // 3. Prompt feedback safety interventions or block reasons.
    if let reason = response.promptFeedback?.blockReason {
      return .refused(
        reason: reason, message: response.promptFeedback?.blockReasonMessage, notices: [],
        details: details)
    }

    // 4. Validate presence of generated candidate content.
    guard let candidate = response.candidates?.first else {
      return .empty(finishReason: nil, details: details)
    }

    // 5. Partition candidate parts, coalescing adjacent text spans and writing image data streams.
    var parts: [OutputPart] = []
    var run: String?
    var undecodable = 0
    func endRun() {
      if let text = run?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        parts.append(.text(text))
      }
      run = nil
    }
    for part in candidate.content?.parts ?? [] where part.thought != true {
      if let text = part.text {
        run = (run ?? "") + text
      } else if let inline = part.inlineData {
        endRun()
        let mime = inline.mimeType ?? "image/jpeg"
        if let image = try decodeImage(inline.data ?? "", mimeType: mime, into: outputDirectory) {
          parts.append(.image(image))
        } else {
          undecodable += 1
        }
      }
    }
    endRun()
    let notices =
      undecodable == 0
      ? [] : [undecodable == 1 ? "1 image could not be decoded" : "\(undecodable) images could not be decoded"]

    // 6. Enforce refusal semantics if image content is absent alongside a non-standard finish reason.
    let hasImage = parts.contains { if case .image = $0 { true } else { false } }
    if !hasImage, let reason = candidate.finishReason, !nonRefusingFinishReasons.contains(reason) {
      return .refused(reason: reason, message: candidate.finishMessage, notices: notices, details: details)
    }

    // 7. Handle empty content outcomes.
    if parts.isEmpty {
      return .empty(finishReason: candidate.finishReason, details: details)
    }

    // 8. Successful candidate materialization.
    return .success(
      parts: parts, finishReason: candidate.finishReason, notices: notices,
      modelVersion: response.modelVersion, responseID: response.responseId, details: details)
  }

  /// Decodes base64 payload into an image file, extracting header dimensions without rasterizing bitmaps.
  private static func decodeImage(_ base64: String, mimeType: String, into directory: URL) throws
    -> StoredOutputImage?
  {
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(
      "\(UUID().uuidString.lowercased()).\(MimeTypes.fileExtension(for: mimeType))")
    try data.write(to: url)
    return StoredOutputImage(
      fileURL: url, mimeType: mimeType, byteCount: data.count, pixelWidth: width, pixelHeight: height)
  }
}
