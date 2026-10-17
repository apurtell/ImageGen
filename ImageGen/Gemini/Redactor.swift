import Foundation

/// Sanitization engine for persisted inspection payloads and diagnostic activity log streams.
/// Enforces data loss prevention guarantees by scrubbing API credentials, stripping opaque model thought signatures,
/// and substituting bulky binary payload runs with size summaries.
enum Redactor {
  static let detailsCap = 64 * 1024
  static let errorBodyLogCap = 2 * 1024
  static let keyRemoved = "<key removed>"

  /// Produces a human readable JSON representation suitable for diagnostic inspection, replacing bulk
  /// image payloads with placeholder summaries and masking model thought signatures within the 64 KB size limit.
  static func details(_ body: Data) -> String {
    // Attempt structured JSON sanitization for top-level dictionary or array containers.
    if let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
      object is [String: Any] || object is [Any],
      let pretty = try? JSONSerialization.data(
        withJSONObject: redactJSON(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    {
      return capped(String(decoding: pretty, as: UTF8.self), maxBytes: detailsCap)
    }
    // Fall back to text-based base64 scrubbing for non-JSON payloads.
    let text = String(decoding: body.prefix(detailsCap * 2), as: UTF8.self)
    return capped(replaceBase64Runs(text), maxBytes: detailsCap)
  }

  /// Traverses parsed JSON object hierarchies to replace sensitive thought signatures and inline base64 image data.
  /// Supports both camelCase and snake_case schema variations.
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

  /// Computes the unpadded decoded byte length of a base64 string through character counting without allocating decoded buffers.
  static func decodedByteCount(ofBase64 s: String) -> Int {
    let significant = s.utf8.filter { b in
      b != UInt8(ascii: "=") && b != UInt8(ascii: " ") && b != UInt8(ascii: "\n")
        && b != UInt8(ascii: "\r") && b != UInt8(ascii: "\t")
    }.count
    return significant * 3 / 4
  }

  /// Constructs a thread-safe sanitization pipeline for telemetry logs. Applies rules in descending order of specificity:
  /// registered secret substrings, well-formed API key regex patterns, URL query parameters, authorization headers,
  /// structured JSON inline binary fields, and arbitrary long base64 string sequences.
  static func forLog(secrets: @escaping @Sendable () -> [String]) -> @Sendable (String) -> String {
    { text in
      var s = text
      // Process registered secrets longest-first to prevent prefix substitution from leaving dangling suffix fragments.
      for secret in secrets().sorted(by: { $0.count > $1.count }) where secret.count >= 8 {
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

  /// Truncates raw HTTP error response strings to 2 KB at valid UTF-8 boundaries, appending overflow byte metrics.
  static func errorBodyForLog(_ body: String) -> String {
    let total = body.utf8.count
    guard total > errorBodyLogCap else { return body }
    let head = utf8Prefix(body, maxBytes: errorBodyLogCap)
    return "\(head)… (+\(total - head.utf8.count) bytes)"
  }

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

  /// Performs regex replacement in reverse index order to preserve UTF-16 match ranges during string mutation.
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

  /// Truncates string content to a maximum byte length while guaranteeing alignment to Unicode scalar boundaries.
  static func utf8Prefix(_ s: String, maxBytes: Int) -> String {
    guard s.utf8.count > maxBytes else { return s }
    var end = s.utf8.index(s.utf8.startIndex, offsetBy: maxBytes)
    while end.samePosition(in: s.unicodeScalars) == nil { end = s.utf8.index(before: end) }
    return String(s.unicodeScalars[..<end])
  }

  /// Caps string representation at a byte ceiling, appending a truncation indicator when bounded.
  static func capped(_ s: String, maxBytes: Int) -> String {
    guard s.utf8.count > maxBytes else { return s }
    let marker = "\n… (truncated)"
    return utf8Prefix(s, maxBytes: maxBytes - marker.utf8.count) + marker
  }
}
