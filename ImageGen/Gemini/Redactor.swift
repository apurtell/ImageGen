import Foundation

/// Redaction for stored details (D§2.7) and for the activity log (D§4.13). Pure.
enum Redactor {
  static let detailsCap = 64 * 1024
  static let errorBodyLogCap = 2 * 1024
  static let keyRemoved = "<key removed>"

  // MARK: Details

  /// Pretty-printed JSON with every `inlineData.data` replaced by `"<N bytes mime>"` and every
  /// `thoughtSignature` by `"<redacted>"`, capped at 64 KB. A body that isn't JSON is kept as
  /// text, with base64-like runs removed, under the same cap.
  static func details(_ body: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
      object is [String: Any] || object is [Any],
      let pretty = try? JSONSerialization.data(
        withJSONObject: redactJSON(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    {
      return capped(String(decoding: pretty, as: UTF8.self), maxBytes: detailsCap)
    }
    let text = String(decoding: body.prefix(detailsCap * 2), as: UTF8.self)
    return capped(replaceBase64Runs(text), maxBytes: detailsCap)
  }

  static func redactJSON(_ value: Any) -> Any {
    if let array = value as? [Any] { return array.map(redactJSON) }
    guard let dict = value as? [String: Any] else { return value }
    var out: [String: Any] = [:]
    for (key, child) in dict {
      switch key {
      case "thoughtSignature":
        out[key] = "<redacted>"
      case "inlineData", "inline_data":
        if var inline = child as? [String: Any], let data = inline["data"] as? String {
          let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String) ?? "image/jpeg"
          inline["data"] = "<\(decodedByteCount(ofBase64: data)) bytes \(mime)>"
          out[key] = inline
        } else {
          out[key] = redactJSON(child)
        }
      default:
        out[key] = redactJSON(child)
      }
    }
    return out
  }

  /// Bytes that a base64 string decodes to, ignoring whitespace and padding.
  static func decodedByteCount(ofBase64 s: String) -> Int {
    let significant = s.utf8.filter { b in
      b != UInt8(ascii: "=") && b != UInt8(ascii: " ") && b != UInt8(ascii: "\n")
        && b != UInt8(ascii: "\r") && b != UInt8(ascii: "\t")
    }.count
    return significant * 3 / 4
  }

  // MARK: Activity log

  /// The sanitizer M4 injects into `ActivityLog`. Removes, in order: every registered secret, any
  /// Gemini-key-shaped text, `key=` query values, `x-goog-api-key` to the end of its line,
  /// `inlineData.data` and `thoughtSignature` values, and base64-like runs of 100+ characters.
  /// Everything else, the prompt included, is unchanged.
  static func forLog(secrets: @escaping @Sendable () -> [String]) -> @Sendable (String) -> String {
    { text in
      var s = text
      for secret in secrets() where secret.count >= 8 {
        s = s.replacingOccurrences(of: secret, with: keyRemoved)
      }
      s = replace(Patterns.keyShaped, in: s) { _ in keyRemoved }
      s = replace(Patterns.keyQuery, in: s) { _ in "key=\(keyRemoved)" }
      s = replace(Patterns.apiKeyHeader, in: s) { _ in "" }
      s = replace(Patterns.inlineDataValue, in: s, group: 2) { "<\($0.count) chars removed>" }
      s = replace(Patterns.thoughtSignatureValue, in: s, group: 2) { "<\($0.count) chars removed>" }
      return replaceBase64Runs(s)
    }
  }

  /// The first 2 KB (cut at a UTF-8 boundary), then `… (+N bytes)`.
  static func errorBodyForLog(_ body: String) -> String {
    let total = body.utf8.count
    guard total > errorBodyLogCap else { return body }
    let head = utf8Prefix(body, maxBytes: errorBodyLogCap)
    return "\(head)… (+\(total - head.utf8.count) bytes)"
  }

  // MARK: Helpers

  private enum Patterns {
    static let keyShaped = try! NSRegularExpression(pattern: "AIza[0-9A-Za-z_-]{35}")
    static let keyQuery = try! NSRegularExpression(pattern: "key=[^&\\s\"'#<>]+")
    static let apiKeyHeader = try! NSRegularExpression(
      pattern: "x-goog-api-key[^\\n]*", options: [.caseInsensitive])
    static let inlineDataValue = try! NSRegularExpression(
      pattern: "(\"inline_?[dD]ata\"\\s*:\\s*\\{[^{}]*?\"data\"\\s*:\\s*\")([^\"]*)(\")")
    static let thoughtSignatureValue = try! NSRegularExpression(
      pattern: "(\"thought_?[sS]ignature\"\\s*:\\s*\")([^\"]*)(\")")
    static let base64Run = try! NSRegularExpression(pattern: "[A-Za-z0-9+/]{100,}")
  }

  static func replaceBase64Runs(_ s: String) -> String {
    replace(Patterns.base64Run, in: s) { "<\($0.count) chars removed>" }
  }

  /// Replaces each match (or its capture `group`) with `transform` of the matched text.
  private static func replace(
    _ regex: NSRegularExpression, in s: String, group: Int = 0, transform: (String) -> String
  ) -> String {
    let ns = s as NSString
    let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return s }
    let out = NSMutableString(string: s)
    for match in matches.reversed() {
      let range = match.range(at: group)
      guard range.location != NSNotFound else { continue }
      out.replaceCharacters(in: range, with: transform(ns.substring(with: range)))
    }
    return out as String
  }

  /// At most `maxBytes` of UTF-8, cut at a Unicode scalar boundary.
  static func utf8Prefix(_ s: String, maxBytes: Int) -> String {
    guard s.utf8.count > maxBytes else { return s }
    var end = s.utf8.index(s.utf8.startIndex, offsetBy: maxBytes)
    while end.samePosition(in: s.unicodeScalars) == nil { end = s.utf8.index(before: end) }
    return String(s.unicodeScalars[..<end])
  }

  /// `s` capped at `maxBytes` of UTF-8, with a truncation marker inside the cap.
  static func capped(_ s: String, maxBytes: Int) -> String {
    guard s.utf8.count > maxBytes else { return s }
    let marker = "\n… (truncated)"
    return utf8Prefix(s, maxBytes: maxBytes - marker.utf8.count) + marker
  }
}
