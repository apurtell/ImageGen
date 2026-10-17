import Foundation

/// Redaction for stored details (D§2.7) and for the activity log (D§4.13). Pure.
///
/// It has two jobs:
/// - `details` makes the readable copy of a response body that a request stores for the Details view.
///   It removes bulk (image data) and opaque tokens (thought signatures), and caps the size.
/// - `forLog` makes the sanitizer for every activity-log message. Its main guarantee is that the API
///   key never reaches the log file or OSLog, whatever route the key takes into a message.
///
/// Callers: `ResponseParser` uses `details` and `utf8Prefix`, and `ModelsClient` uses `utf8Prefix`.
/// `AppEnvironment` builds the log sanitizer once, with the `SecretRegistry` as its source of secrets.
///
/// Concurrency: no state that changes. The compiled patterns are immutable static constants, which are
/// safe to share between threads. The log sanitizer is a `@Sendable` closure, so the activity log can
/// call it from any thread, before it takes its lock (D§4.13).
enum Redactor {
  static let detailsCap = 64 * 1024
  static let errorBodyLogCap = 2 * 1024
  static let keyRemoved = "<key removed>"

  // MARK: Details

  /// Pretty-printed JSON with every `inlineData.data` replaced by `"<N bytes mime>"` and every
  /// `thoughtSignature` by `"<redacted>"`, capped at 64 KB. A body that isn't JSON is kept as
  /// text, with base64-like runs removed, under the same cap.
  static func details(_ body: Data) -> String {
    // Only a top-level object or array takes the JSON path. A bare JSON string or number is kept as
    // text, so the base64 pass below still sees it.
    if let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),  // Not JSON: text path.
      object is [String: Any] || object is [Any],
      let pretty = try? JSONSerialization.data(  // A failure falls back to the text path.
        withJSONObject: redactJSON(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    {
      return capped(String(decoding: pretty, as: UTF8.self), maxBytes: detailsCap)
    }
    // Twice the cap, because removing base64 runs can shrink the text below the cap again.
    let text = String(decoding: body.prefix(detailsCap * 2), as: UTF8.self)
    return capped(replaceBase64Runs(text), maxBytes: detailsCap)
  }

  /// Walks a `JSONSerialization` tree and returns a copy with the two kinds of value replaced. It
  /// accepts both the camelCase and the snake_case key spellings, so either form of the JSON is redacted.
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

  /// Bytes that a base64 string decodes to, ignoring whitespace and padding. It counts characters
  /// instead of decoding, so a large image costs no extra memory.
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
  ///
  /// Why this order: the most exact rule runs first. A registered secret is the exact key text, so it
  /// goes first, before a pattern can rewrite part of it and leave the rest. For example, if a secret
  /// starts with a key-shaped prefix but is longer, the key-shape rule removes only the first 39
  /// characters and leaves the tail. The broad base64 rule runs last. It catches long data that the
  /// shaped rules missed.
  ///
  /// The markers contain `<`, `>` and spaces. Neither the `key=` pattern nor the base64 pattern accepts
  /// those characters, so a later rule does not rewrite an earlier marker.
  ///
  /// `secrets` is called once for each message, so a key registered a moment ago applies at once.
  /// Swift note: `@escaping` means the closure is kept after `forLog` returns; `@Sendable` means it
  /// can run on any thread.
  static func forLog(secrets: @escaping @Sendable () -> [String]) -> @Sendable (String) -> String {
    { text in
      var s = text
      // Longest first: a shorter secret inside a longer one (a truncated paste validated earlier)
      // would otherwise cut the longer one apart and leave its tail in the text.
      // Secrets shorter than 8 characters are skipped: a very short string would remove ordinary
      // words from the text, and no real key is that short.
      for secret in secrets().sorted(by: { $0.count > $1.count }) where secret.count >= 8 {
        s = s.replacingOccurrences(of: secret, with: keyRemoved)
      }
      s = replace(Patterns.keyShaped, in: s) { _ in keyRemoved }
      s = replace(Patterns.keyQuery, in: s) { _ in "key=\(keyRemoved)" }
      // Anything after the header name on that line can be the key, so the whole rest of the line goes.
      s = replace(Patterns.apiKeyHeader, in: s) { _ in "" }
      // Group 2 is only the value between the quotes, so the key and quotes stay and the JSON shape
      // remains readable.
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

  /// The compiled patterns. Swift note: a `static let` is created once, on first use, and creation is
  /// thread-safe. The `try!` cannot fail at run time, because each pattern is a constant that the
  /// tests exercise.
  private enum Patterns {
    /// The documented Gemini key form: `AIza` and 35 more characters.
    static let keyShaped = try! NSRegularExpression(pattern: "AIza[0-9A-Za-z_-]{35}")
    static let keyQuery = try! NSRegularExpression(pattern: "key=[^&\\s\"'#<>]+")
    static let apiKeyHeader = try! NSRegularExpression(
      pattern: "x-goog-api-key[^\\n]*", options: [.caseInsensitive])
    /// The `data` string inside an `inlineData` (or `inline_data`) object. `[^{}]*?` keeps the match
    /// inside that one object.
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
  ///
  /// `NSRegularExpression` works in UTF-16 offsets (`NSRange`), so the text is handled as an
  /// `NSString`. The loop replaces from the last match to the first, so each replacement leaves the
  /// offsets of the earlier matches valid.
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

  /// At most `maxBytes` of UTF-8, cut at a Unicode scalar boundary. It steps back from the byte limit
  /// until the cut is between two scalars, so the result is always valid text.
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
