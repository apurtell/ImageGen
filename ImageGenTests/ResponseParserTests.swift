import CoreGraphics
import Foundation
import Testing

@testable import ImageGen

@Suite
struct ResponseParserTests {
  enum PartShape: Equatable, Sendable {
    case text(String)
    case image(mime: String, width: Int, height: Int)
  }

  enum Expected: Sendable {
    case success([PartShape], finish: String?, notices: [String] = [])
    case refused(String, message: String? = nil, notices: [String] = [], detailsContain: String? = nil)
    case empty(finish: String?)
    case apiError(Int, status: String?, messageContains: String)
    case malformed
  }

  struct Row: Sendable, CustomTestStringConvertible {
    let file: String
    var status = 200
    let expected: Expected
    var testDescription: String { file }
  }

  static let png = PartShape.image(mime: "image/png", width: 16, height: 9)
  static let jpg = PartShape.image(mime: "image/jpeg", width: 8, height: 8)
  static let notDecoded = ["1 image could not be decoded"]

  static let rows: [Row] = [
    Row(file: "Responses/resp_text_image.json", expected: .success([.text("Here is your lighthouse at dusk."), png], finish: "STOP")),
    Row(file: "Responses/resp_image_text.json", expected: .success([png, .text("A lighthouse, as requested.")], finish: "STOP")),
    Row(file: "Responses/resp_two_images.json", expected: .success([png, jpg], finish: "STOP")),
    Row(file: "Responses/resp_adjacent_text.json", expected: .success([.text("First part, second part."), png], finish: "STOP")),
    Row(
      file: "Responses/resp_split_sentence.json",
      expected: .success([.text("The lighthouse stands on a rocky point."), png, .text("- item 1\n- item 2")], finish: "STOP")),
    Row(file: "Responses/resp_whitespace_run.json", expected: .success([png], finish: "STOP")),
    Row(file: "Responses/resp_thought_parts.json", expected: .success([jpg], finish: "STOP")),
    Row(file: "Responses/resp_no_mime.json", expected: .success([jpg], finish: "STOP")),
    Row(file: "Responses/resp_bad_image.json", expected: .success([.text("Here you go.")], finish: "STOP", notices: notDecoded)),
    Row(file: "Responses/resp_text_only.json", expected: .success([.text("I can describe it: a tall white lighthouse.")], finish: "STOP")),
    Row(file: "Responses/resp_finish_no_image.json", expected: .refused("NO_IMAGE", detailsContain: "I couldn't make that image.")),
    Row(file: "Responses/resp_prompt_refused.json", expected: .refused("PROHIBITED_CONTENT")),
    Row(
      file: "Responses/resp_image_safety.json",
      expected: .refused("IMAGE_SAFETY", message: "The image was blocked by the safety filter.")),
    Row(file: "Responses/resp_image_other.json", expected: .refused("IMAGE_OTHER")),
    Row(file: "Responses/resp_no_image_no_parts.json", expected: .refused("NO_IMAGE")),
    Row(
      file: "Responses/resp_refused_with_text.json",
      expected: .refused("IMAGE_SAFETY", detailsContain: "Sorry, I can't generate that image.")),
    Row(file: "Responses/resp_unknown_finish_reason.json", expected: .refused("IMAGE_SOMETHING_NEW")),
    Row(file: "Responses/resp_escalation.json", expected: .refused("ESCALATION")),
    Row(file: "Responses/resp_pup_limited.json", expected: .refused("PUP_LIMITED_DISABLED")),
    Row(file: "Responses/resp_empty_candidates.json", expected: .empty(finish: nil)),
    Row(file: "Responses/resp_no_parts_other.json", expected: .refused("OTHER")),
    Row(file: "Responses/resp_no_parts_stop.json", expected: .empty(finish: "STOP")),
    Row(file: "Responses/resp_no_parts_max_tokens.json", expected: .empty(finish: "MAX_TOKENS")),
    Row(file: "Responses/resp_no_parts_unspecified.json", expected: .empty(finish: "FINISH_REASON_UNSPECIFIED")),
    Row(file: "Responses/resp_no_parts_no_finish.json", expected: .empty(finish: nil)),
    Row(file: "Responses/resp_text_only_max_tokens.json", expected: .success([.text("A tall white lighthouse on a")], finish: "MAX_TOKENS")),
    Row(
      file: "Responses/resp_text_only_unspecified.json",
      expected: .success([.text("A tall white lighthouse.")], finish: "FINISH_REASON_UNSPECIFIED")),
    Row(file: "Responses/resp_text_only_no_finish.json", expected: .success([.text("A tall white lighthouse.")], finish: nil)),
    Row(
      file: "Responses/resp_image_with_safety_finish.json",
      expected: .success([.text("Here is a partial result."), png], finish: "IMAGE_SAFETY")),
    Row(file: "Responses/resp_bad_image_refused.json", expected: .refused("IMAGE_SAFETY", notices: notDecoded)),
    Row(file: "Responses/resp_malformed.txt", expected: .malformed),
    Row(file: "Responses/resp_html.html", expected: .malformed),
    Row(file: "Responses/resp_unexpected_shape.json", expected: .empty(finish: nil)),
    Row(
      file: "Errors/err_400_invalid_argument.json", status: 400,
      expected: .apiError(400, status: "INVALID_ARGUMENT", messageContains: "Unsupported value for imageConfig.aspectRatio")),
    Row(
      file: "Errors/err_400_civic.json", status: 400,
      expected: .apiError(400, status: "INVALID_ARGUMENT", messageContains: "HARM_CATEGORY_CIVIC_INTEGRITY")),
    Row(
      file: "Errors/err_400_api_key_invalid.json", status: 400,
      expected: .apiError(400, status: "INVALID_ARGUMENT", messageContains: "API key not valid")),
    Row(file: "Errors/err_402.json", status: 402, expected: .apiError(402, status: "FAILED_PRECONDITION", messageContains: "credits")),
    Row(file: "Errors/err_403.json", status: 403, expected: .apiError(403, status: "PERMISSION_DENIED", messageContains: "unregistered")),
    Row(file: "Errors/err_404.json", status: 404, expected: .apiError(404, status: "NOT_FOUND", messageContains: "is not found")),
    Row(file: "Errors/err_429_retryinfo.json", status: 429, expected: .apiError(429, status: "RESOURCE_EXHAUSTED", messageContains: "quota")),
    Row(file: "Errors/err_500_text.txt", status: 500, expected: .apiError(500, status: nil, messageContains: "Internal Server Error")),
    Row(file: "Errors/err_503.json", status: 503, expected: .apiError(503, status: "UNAVAILABLE", messageContains: "overloaded")),
  ]

  static func parse(_ file: String, status: Int = 200, root: TestFileRoot) async throws -> ParsedOutcome {
    try await ResponseParser.parse(
      httpStatus: status, bodyURL: try FixtureLoader.url(file), outputDirectory: root.directory("out-1"))
  }

  static func shapes(_ parts: [OutputPart]) -> [PartShape] {
    parts.map {
      switch $0 {
      case .text(let t): .text(t)
      case .image(let i): .image(mime: i.mimeType, width: i.pixelWidth, height: i.pixelHeight)
      }
    }
  }

  static func details(_ o: ParsedOutcome) -> String {
    switch o {
    case .success(_, _, _, _, _, let d), .refused(_, _, _, let d), .empty(_, let d), .apiError(_, _, _, let d),
      .malformed(let d):
      d
    }
  }

  @Test(.tags(.io), arguments: rows)
  func fixtureOutcome(_ row: Row) async throws {
    let root = TestFileRoot()
    let outcome = try await Self.parse(row.file, status: row.status, root: root)
    let written = (try? FileManager.default.contentsOfDirectory(atPath: root.url.appendingPathComponent("out-1").path)) ?? []

    switch (row.expected, outcome) {
    case (.success(let shapes, let finish, let notices), .success(let parts, let f, let n, let version, let responseID, _)):
      #expect(Self.shapes(parts) == shapes)
      #expect(f == finish)
      #expect(n == notices)
      #expect(version == "gemini-3.1-flash-image")
      #expect(responseID == "resp-abc123")
      #expect(written.count == shapes.filter { if case .image = $0 { true } else { false } }.count)
    case (.refused(let reason, let message, let notices, let contains), .refused(let r, let m, let n, let d)):
      #expect(r == reason)
      #expect(m == message)
      #expect(n == notices)
      if let contains { #expect(d.contains(contains)) }
      #expect(written.isEmpty)
    case (.empty(let finish), .empty(let f, _)):
      #expect(f == finish)
    case (.apiError(let status, let rpc, let contains), .apiError(let s, let r, let m, let d)):
      #expect(s == status)
      #expect(r == rpc)
      #expect(m.contains(contains))
      #expect(!d.isEmpty)
    case (.malformed, .malformed(let d)):
      #expect(!d.isEmpty)
    default:
      Issue.record("\(row.file): expected \(row.expected), got \(outcome)")
    }
  }

  @Test(.tags(.io)) func everyFixtureHasARow() throws {
    let covered = Set(Self.rows.map(\.file))
    for folder in ["Responses", "Errors"] {
      for name in try FixtureLoader.names(in: folder) {
        #expect(covered.contains("\(folder)/\(name)"), "no row for \(folder)/\(name)")
      }
    }
  }

  @Test(.tags(.io)) func imagesWrittenByteIdenticalToDecodedBase64() async throws {
    let root = TestFileRoot()
    let file = "Responses/resp_two_images.json"
    let json = try #require(try JSONSerialization.jsonObject(with: FixtureLoader.data(file)) as? [String: Any])
    let parts = try #require(
      (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]) as? [[String: Any]])
    let expected = parts.compactMap { ($0["inlineData"] as? [String: String])?["data"] }.map { Data(base64Encoded: $0)! }
    guard case .success(let out, _, _, _, _, _) = try await Self.parse(file, root: root) else {
      Issue.record("not success")
      return
    }
    let images = out.compactMap { if case .image(let i) = $0 { i } else { nil } }
    #expect(images.count == 2)
    for (image, bytes) in zip(images, expected) {
      #expect(try Data(contentsOf: image.fileURL) == bytes)
      #expect(image.byteCount == bytes.count)
      #expect(image.fileURL.deletingLastPathComponent().lastPathComponent == "out-1")
    }
    #expect(images.map { $0.fileURL.pathExtension } == ["png", "jpg"])
  }

  @Test(.tags(.io)) func noMimeDefaultsToJpeg() async throws {
    let root = TestFileRoot()
    guard case .success(let parts, _, _, _, _, _) = try await Self.parse("Responses/resp_no_mime.json", root: root),
      case .image(let image) = parts.first
    else {
      Issue.record("not an image")
      return
    }
    #expect(image.mimeType == "image/jpeg")
    #expect(image.fileURL.pathExtension == "jpg")
  }

  @Test(.tags(.io), arguments: rows.map(\.file))
  func redactedDetailsHaveNoLongBase64(file: String) async throws {
    let root = TestFileRoot()
    let status = Self.rows.first { $0.file == file }!.status
    let details = Self.details(try await Self.parse(file, status: status, root: root))
    #expect(details.range(of: "[A-Za-z0-9+/]{100,}", options: .regularExpression) == nil)
    #expect(!details.contains("c2lnbmF0dXJlLW9wYXF1ZS1ieXRlcy0xMjM0NTY3ODkw"))
  }

  @Test(.tags(.io)) func detailsShowImageSizeAndRedactedSignature() async throws {
    let root = TestFileRoot()
    let details = Self.details(try await Self.parse("Responses/resp_thought_parts.json", root: root))
    #expect(details.contains("bytes image/jpeg>"))
    #expect(details.contains("\"<redacted>\""))
  }

  @Test(.tags(.io)) func detailsCappedAt64KB() async throws {
    let root = TestFileRoot()
    let longText = String(repeating: "The lighthouse keeper writes another line. ", count: 4000)
    let body = try JSONSerialization.data(withJSONObject: [
      "candidates": [["content": ["parts": [["text": longText]]], "finishReason": "STOP"]]
    ])
    let url = root.file("body.json")
    try body.write(to: url)
    let outcome = try await ResponseParser.parse(httpStatus: 200, bodyURL: url, outputDirectory: root.directory("out"))
    let details = Self.details(outcome)
    #expect(details.utf8.count <= 64 * 1024)
    #expect(details.utf8.count > 60 * 1024)
  }

  @Test(.tags(.io)) func errorBodyFirst2KBForNonJSON() async throws {
    let root = TestFileRoot()
    let text = try FixtureLoader.string("Errors/err_500_text.txt")
    #expect(text.utf8.count > 2048)
    guard case .apiError(500, nil, let message, let details) = try await Self.parse("Errors/err_500_text.txt", status: 500, root: root)
    else {
      Issue.record("not an apiError")
      return
    }
    #expect(message == String(decoding: Data(text.utf8).prefix(2048), as: UTF8.self))
    #expect(details == text)
  }

  @Test(.tags(.io)) func errorHelpersReadDetails() throws {
    let rate = try #require(GeminiErrorBody.decode(FixtureLoader.data("Errors/err_429_retryinfo.json")))
    #expect(rate.retryDelay == .seconds(30))
    let key = try #require(GeminiErrorBody.decode(FixtureLoader.data("Errors/err_400_api_key_invalid.json")))
    #expect(key.reason == "API_KEY_INVALID")
    #expect(key.retryDelay == nil)
    let civic = try #require(GeminiErrorBody.decode(FixtureLoader.data("Errors/err_400_civic.json")))
    #expect(civic.mentionsCivicIntegrity)
    #expect(GeminiErrorBody.decode(Data("{\"foo\":1}".utf8)) == nil)
    #expect(GeminiErrorBody.decode(Data("<html>".utf8)) == nil)
  }

  @Test(.tags(.io)) func parsesFromMappedFileOfThirtyMB() async throws {
    let root = TestFileRoot()
    // Synthesizes a high entropy incompressible PNG (~24 MB) producing a response body exceeding 30 MB.
    let side = 2850
    var rng = SystemRandomNumberGenerator()
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    pixels.withUnsafeMutableBytes { raw in
      let words = raw.bindMemory(to: UInt64.self)
      for i in words.indices { words[i] = rng.next() }
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
      width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let png = ImageFactory.encode(image, type: .png)

    let url = root.file("response-1.part")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(#"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":""#.utf8))
    try handle.write(contentsOf: png.base64EncodedData())
    try handle.write(contentsOf: Data(#""}}]},"finishReason":"STOP"}]}"#.utf8))
    try handle.close()
    let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    #expect(size > 30_000_000)

    let outcome = try await ResponseParser.parse(httpStatus: 200, bodyURL: url, outputDirectory: root.directory("out-1"))
    guard case .success(let parts, "STOP", [], _, _, let details) = outcome, case .image(let out) = parts.first else {
      Issue.record("expected one image, got \(outcome)")
      return
    }
    #expect(parts.count == 1)
    #expect((out.pixelWidth, out.pixelHeight) == (side, side))
    #expect(out.byteCount == png.count)
    #expect(try Data(contentsOf: out.fileURL) == png)
    #expect(details.utf8.count < 2048)
  }
}
