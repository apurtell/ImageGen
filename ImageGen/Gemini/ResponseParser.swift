import Foundation
import ImageIO

/// A decoded output image, already written to the caller's output directory.
struct StoredOutputImage: Sendable, Equatable {
  let fileURL: URL
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

enum OutputPart: Sendable, Equatable {
  case text(String)
  case image(StoredOutputImage)
}

enum ParsedOutcome: Sendable {
  case success(
    parts: [OutputPart], finishReason: String?, notices: [String], modelVersion: String?,
    responseID: String?, details: String)
  /// `reason` is verbatim (D§2.7 rules 3 and 6); `message` is `finishMessage`. `notices` keeps
  /// the "could not be decoded" notice when the only image parts were undecodable.
  case refused(reason: String, message: String?, notices: [String], details: String)
  case empty(finishReason: String?, details: String)
  case apiError(httpStatus: Int, status: String?, message: String, details: String)
  case malformed(details: String)
}

/// Parses a `generateContent` response body file (D§2.7). Pure apart from writing the decoded
/// images to `outputDirectory`; it doesn't log.
enum ResponseParser {
  /// Finish reasons that don't make an image-less candidate a refusal.
  static let nonRefusingFinishReasons: Set<String> = ["STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED"]

  /// Throws only when writing an image fails (for example, the disk is full, D§6 #27).
  @concurrent
  static func parse(httpStatus: Int, bodyURL: URL, outputDirectory: URL) async throws -> ParsedOutcome {
    let body = (try? Data(contentsOf: bodyURL, options: .mappedIfSafe)) ?? Data()

    // 1. Not 2xx: an API error.
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

    // 2. Not a response.
    guard let response = try? JSONDecoder().decode(GenerateContentResponse.self, from: body) else {
      return .malformed(details: Redactor.details(body))
    }
    let details = Redactor.details(body)

    // 3. The prompt was refused.
    if let reason = response.promptFeedback?.blockReason {
      return .refused(
        reason: reason, message: response.promptFeedback?.blockReasonMessage, notices: [],
        details: details)
    }

    // 4. No candidates.
    guard let candidate = response.candidates?.first else {
      return .empty(finishReason: nil, details: details)
    }

    // 5. Parts in order, thoughts dropped; text runs joined verbatim and trimmed at their ends.
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

    // 6. No image and a refusing finish reason: refused, whatever text came back.
    let hasImage = parts.contains { if case .image = $0 { true } else { false } }
    if !hasImage, let reason = candidate.finishReason, !nonRefusingFinishReasons.contains(reason) {
      return .refused(reason: reason, message: candidate.finishMessage, notices: notices, details: details)
    }

    // 7. Nothing left.
    if parts.isEmpty {
      return .empty(finishReason: candidate.finishReason, details: details)
    }

    // 8. Success.
    return .success(
      parts: parts, finishReason: candidate.finishReason, notices: notices,
      modelVersion: response.modelVersion, responseID: response.responseId, details: details)
  }

  /// Decodes, checks and writes one image; nil when the bytes aren't an image.
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
