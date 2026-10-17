import Foundation
import ImageIO

/// A decoded output image, already written to the caller's output directory. The outcome holds this
/// file reference, never the image bytes (D§2.7, *Memory*).
struct StoredOutputImage: Sendable, Equatable {
  let fileURL: URL
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

/// One block of a reply, in the order the model returned it.
enum OutputPart: Sendable, Equatable {
  case text(String)
  case image(StoredOutputImage)
}

/// The parser's result for one attempt (D§2.7). Swift note: each case carries its own data (see the
/// primer, *Enum with associated values*), and a `switch` over it must handle every case.
/// `GenerationService` maps each case to a request state and a reply. Every case carries `details`:
/// the redacted body, capped at 64 KB, for the Details view.
enum ParsedOutcome: Sendable {
  case success(
    parts: [OutputPart], finishReason: String?, notices: [String], modelVersion: String?,
    responseID: String?, details: String)
  /// `reason` is verbatim (D§2.7 rules 3 and 6); `message` is `finishMessage`. `notices` keeps
  /// the "could not be decoded" notice when the only image parts were undecodable.
  case refused(reason: String, message: String?, notices: [String], details: String)
  case empty(finishReason: String?, details: String)
  /// A status outside 2xx. `status` and `message` come from a Google RPC error body when there is one.
  case apiError(httpStatus: Int, status: String?, message: String, details: String)
  case malformed(details: String)
}

/// Parses a `generateContent` response body file (D§2.7). Pure apart from writing the decoded
/// images to `outputDirectory`; it doesn't log.
///
/// Place in the design: the transport saves the response body to a file. `GenerationService` then
/// calls `parse` with that file and the attempt's output folder (`Requests/<id>/out-<attempt>/`), and
/// moves the image files into the chat's folder when it saves the reply. The numbered comments in
/// `parse` are the rules of D§2.7, in the same order; the first rule that matches gives the result.
///
/// Memory: the body file is memory-mapped, not copied. The decoded response holds each image's base64
/// as a string. Each image is decoded and written to its own file at once, then released. Nothing keeps
/// the base64 strings or the image bytes after `parse` returns.
///
/// Concurrency: no shared state. `parse` runs off the caller's actor (`@concurrent`), so a large
/// response does not block `GenerationService` while it decodes.
enum ResponseParser {
  /// Finish reasons that don't make an image-less candidate a refusal.
  static let nonRefusingFinishReasons: Set<String> = ["STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED"]

  /// Throws only when writing an image fails (for example, the disk is full, D§6 #27). Every other
  /// problem in the body is an outcome, not an error.
  ///
  /// Swift note: `@concurrent` runs this `async` function on a background thread, away from the
  /// caller's actor. See the primer, *Tasks and cancellation*.
  @concurrent
  static func parse(httpStatus: Int, bodyURL: URL, outputDirectory: URL) async throws -> ParsedOutcome {
    // `.mappedIfSafe` maps the file instead of copying it into memory.
    let body = (try? Data(contentsOf: bodyURL, options: .mappedIfSafe)) ?? Data()  // A missing file is an empty body; rule 1 or 2 reports it.

    // 1. Not 2xx: an API error.
    guard (200..<300).contains(httpStatus) else {
      let details = Redactor.details(body)
      if let error = GeminiErrorBody.decode(body) {
        return .apiError(
          httpStatus: httpStatus, status: error.status,
          message: error.message ?? "", details: details)
      }
      // Not a Google RPC error: the message is the first 2 KB of the body, as the pipe does. Only the
      // first 4 KB is converted, and the cut is at a character boundary.
      let text = Redactor.utf8Prefix(String(decoding: body.prefix(4096), as: UTF8.self), maxBytes: 2048)
      return .apiError(httpStatus: httpStatus, status: nil, message: text, details: details)
    }

    // 2. Not a response.
    guard let response = try? JSONDecoder().decode(GenerateContentResponse.self, from: body) else {  // Any decode error is rule 2.
      return .malformed(details: Redactor.details(body))
    }
    // The redacted copy for the Details view. It replaces image data and thought signatures (D§2.7).
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
    // `run` collects consecutive text parts. An image part or the end of the parts closes the run.
    var parts: [OutputPart] = []
    var run: String?
    var undecodable = 0
    // A nested function that captures and changes `parts` and `run` above.
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
        // The pipe's default when the MIME type is missing (D§2.7 rule 5).
        let mime = inline.mimeType ?? "image/jpeg"
        if let image = try decodeImage(inline.data ?? "", mimeType: mime, into: outputDirectory) {
          parts.append(.image(image))
        } else {
          // Dropped, not stored, so the next edit uses the previous real image (D§2.6).
          undecodable += 1
        }
      }
    }
    endRun()
    let notices =
      undecodable == 0
      ? [] : [undecodable == 1 ? "1 image could not be decoded" : "\(undecodable) images could not be decoded"]

    // 6. No image and a refusing finish reason: refused, whatever text came back. The text stays only
    //    in `details`. An unknown finish reason counts as refusing, so new API values are safe.
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
  ///
  /// It reads only the image header (the pixel size), not the pixels, so the check is cheap. It
  /// writes the original bytes, never a re-encoded copy. The file name is a new UUID, so two images in
  /// one response cannot collide.
  private static func decodeImage(_ base64: String, mimeType: String, into directory: URL) throws
    -> StoredOutputImage?
  {
    // Swift note: one `guard` checks several conditions in order and unwraps each value. The first
    // failure returns nil. See the primer, *Errors and early exits*.
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
