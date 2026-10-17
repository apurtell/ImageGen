import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct RedactorTests {
  static let b64 = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", count: 6)  // 210 characters.
  let sanitize = Redactor.forLog(secrets: { [] })

  func object(_ s: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(s.utf8)) }

  @Test func overlappingSecretsRemovedWhole() {
    let full = "AIzaSyD-0123456789abcdefghijklmnopqrstu"
    let truncated = String(full.prefix(20))
    // Verifies longest match precedence regardless of secret registration order.
    for order in [[truncated, full], [full, truncated]] {
      let out = Redactor.forLog(secrets: { order })("echo \(full) end")
      #expect(out == "echo \(Redactor.keyRemoved) end")
    }
  }

  @Test func nestedArrays() throws {
    let body = """
      {"candidates":[{"content":{"parts":[[{"inlineData":{"mimeType":"image/png","data":"\(Self.b64)"}}],
        {"inlineData":{"data":"QUJD"}}]}}]}
      """
    let details = Redactor.details(Data(body.utf8))
    #expect(details.contains("\"<157 bytes image/png>\""))
    #expect(details.contains("\"<3 bytes image/jpeg>\""))
    #expect(!details.contains(Self.b64))
  }

  @Test func thoughtSignatures() {
    let details = Redactor.details(Data(#"{"parts":[{"text":"hi","thoughtSignature":"c2lnbmF0dXJl"}]}"#.utf8))
    #expect(details.contains(#""thoughtSignature" : "<redacted>""#))
    #expect(!details.contains("c2lnbmF0dXJl"))
  }

  @Test func nonDataStringsUnchanged() throws {
    let body = #"{"modelVersion":"gemini-3.1-flash-image","candidates":[{"content":{"parts":[{"text":"data: keep \"me\""}]},"finishReason":"STOP"}],"data":"top-level data stays"}"#
    let redacted = try object(Redactor.details(Data(body.utf8)))
    #expect((redacted as? NSObject)?.isEqual(try object(body)) == true)
  }

  @Test func nonJSONKeptAsText() {
    #expect(Redactor.details(Data("<html>portal</html>".utf8)) == "<html>portal</html>")
    let withRun = Redactor.details(Data("truncated {\"data\":\"\(Self.b64)".utf8))
    #expect(withRun == "truncated {\"data\":\"<210 chars removed>")
  }

  @Test func forLogRemovesBase64Runs() {
    let out = sanitize("body: \(Self.b64) end")
    #expect(out == "body: <210 chars removed> end")
    #expect(sanitize(String(repeating: "A", count: 99)) == String(repeating: "A", count: 99))
  }

  @Test func forLogRemovesInlineDataAndThoughtSignature() {
    let out = sanitize(#"{"inlineData": {"mimeType": "image/png", "data": "QUJDRA=="}, "thoughtSignature": "c2ln"}"#)
    #expect(out == #"{"inlineData": {"mimeType": "image/png", "data": "<8 chars removed>"}, "thoughtSignature": "<4 chars removed>"}"#)
  }

  @Test func forLogRedactsKeyQuery() {
    let out = sanitize("GET https://generativelanguage.googleapis.com/v1beta/models?key=abc123XYZ&pageSize=1000")
    #expect(out == "GET https://generativelanguage.googleapis.com/v1beta/models?key=<key removed>&pageSize=1000")
  }

  @Test func forLogRemovesRegisteredSecretAnywhere() {
    let secret = "hunter2-not-key-shaped"
    let sanitize = Redactor.forLog(secrets: { [secret, ""] })
    let inputs = [
      "prompt: draw \(secret) as a cat",
      "The key \(secret). Next sentence.",
      "https://example.test/path/\(secret)/x",
    ]
    for input in inputs {
      let out = sanitize(input)
      #expect(!out.contains(secret))
      #expect(out.contains("<key removed>"))
    }
    #expect(sanitize("prompt: draw \(secret) as a cat") == "prompt: draw <key removed> as a cat")
  }

  @Test func forLogRemovesKeyShapedText() {
    let key = "AIza" + String(repeating: "Ab3_-", count: 7)  // Synthesizes standard 39-character Gemini API key pattern.
    #expect(key.count == 39)
    #expect(sanitize("error: bad key \(key) here") == "error: bad key <key removed> here")
  }

  @Test func forLogDropsApiKeyHeaderText() {
    let out = sanitize("headers:\nx-goog-api-key: s3cr3t-value\nAccept: application/json")
    #expect(!out.contains("x-goog-api-key"))
    #expect(!out.contains("s3cr3t-value"))
    #expect(out == "headers:\n\nAccept: application/json")
  }

  @Test func forLogKeepsPromptText() {
    let prompt = "A \"quoted\" lighthouse,\nnewline\ttab 🎨🏝️ — key ideas: dusk; data=none"
    #expect(sanitize(prompt) == prompt)
  }

  @Test func errorBodyForLogCapsAt2KB() {
    let short = "short body"
    #expect(Redactor.errorBodyForLog(short) == short)
    let body = String(repeating: "x", count: 2047) + "é" + String(repeating: "y", count: 3000)
    let out = Redactor.errorBodyForLog(body)
    // Multibyte UTF-8 boundary protection: splits prior to character boundary to avoid encoding corruptions.
    #expect(out == String(repeating: "x", count: 2047) + "… (+3002 bytes)")
  }

  @Test func detailsCapKeepsValidUTF8() {
    let s = String(repeating: "🎨", count: 20_000)  // 80 KB payload.
    let capped = Redactor.capped(s, maxBytes: 64 * 1024)
    #expect(capped.utf8.count <= 64 * 1024)
    #expect(capped.hasSuffix("… (truncated)"))
    #expect(!capped.unicodeScalars.contains("\u{FFFD}"))
  }
}
