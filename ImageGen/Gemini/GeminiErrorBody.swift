import Foundation

// Decoding of the error body that Google APIs return for a failed call. `ResponseParser` (for
// `generateContent`) and `ModelsClient` (for the models calls) use it. The pipeline's retry policy
// reads `retryDelay`, and the CIVIC fallback reads `mentionsCivicIntegrity` (D§2.4).
// All types here are values with no shared state, so any task can use them.

/// Any JSON value, for the open-ended `error.details` entries.
///
/// Swift note: each case carries the value of one JSON kind (see the primer, *Enum with associated
/// values*). This lets the code read a few known fields of a detail and ignore the rest.
enum AnyJSON: Sendable, Equatable, Decodable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([AnyJSON])
  case object([String: AnyJSON])

  /// Tries each JSON kind in turn; `try?` turns "not this kind" into "try the next one". `Bool` comes
  /// before `Double`, so `true` does not become `1`. An object is the last case, and its failure is
  /// the error for a value of no known kind.
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {  // Not a Bool: try the next kind.
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {  // Not a number: try the next kind.
      self = .number(n)
    } else if let s = try? c.decode(String.self) {  // Not a string: try the next kind.
      self = .string(s)
    } else if let a = try? c.decode([AnyJSON].self) {  // Not an array: try an object last.
      self = .array(a)
    } else {
      self = .object(try c.decode([String: AnyJSON].self))
    }
  }

  /// The member `key` of an object; nil for a missing key or for a value that is not an object.
  /// So chains like `detail["@type"]?.string` stay short and never fail.
  subscript(key: String) -> AnyJSON? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  var string: String? {
    if case .string(let s) = self { return s }
    return nil
  }
}

/// A Google RPC error body: `{"error":{"code","message","status","details":[…]}}`.
///
/// Every field is optional, because error bodies vary. Decoding fails only when there is no `error`
/// object, so a successful response or a body from a proxy is not mistaken for an API error.
struct GeminiErrorBody: Sendable, Equatable, Decodable {
  var code: Int?
  var message: String?
  var status: String?
  var details: [AnyJSON]

  // The wire shape. The public fields above flatten it.
  private struct Envelope: Decodable { var error: Inner? }
  private struct Inner: Decodable {
    var code: Int?
    var message: String?
    var status: String?
    var details: [AnyJSON]?
  }

  init(code: Int?, message: String?, status: String?, details: [AnyJSON] = []) {
    self.code = code
    self.message = message
    self.status = status
    self.details = details
  }

  init(from decoder: Decoder) throws {
    guard let inner = try Envelope(from: decoder).error else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "no error object"))
    }
    self.init(code: inner.code, message: inner.message, status: inner.status, details: inner.details ?? [])
  }

  /// The decoded body, or nil when the data isn't a Google RPC error.
  static func decode(_ data: Data) -> GeminiErrorBody? {
    try? JSONDecoder().decode(GeminiErrorBody.self, from: data)  // Not an RPC error: the caller uses the raw text.
  }

  /// `google.rpc.RetryInfo.retryDelay`, for example `"30s"` or `"1.5s"`.
  /// A detail with a value in another form (no `s`, negative, not a number) is skipped, not an error.
  /// The `@type` check uses a suffix, because the full value carries a URL prefix
  /// (`type.googleapis.com/…`).
  var retryDelay: Duration? {
    for detail in details where detail["@type"]?.string?.hasSuffix("google.rpc.RetryInfo") == true {
      guard let text = detail["retryDelay"]?.string, text.hasSuffix("s"),
        let seconds = Double(text.dropLast()), seconds >= 0
      else { continue }
      return .seconds(seconds)
    }
    return nil
  }

  /// `google.rpc.ErrorInfo.reason`, for example `API_KEY_INVALID`.
  var reason: String? {
    details.first { $0["@type"]?.string?.hasSuffix("google.rpc.ErrorInfo") == true }?["reason"]?.string
  }

  /// The deprecated-category rejection that triggers the CIVIC fallback (D§2.4). This property checks
  /// only the message. `RetryPolicy` also checks for HTTP 400 and a status of `INVALID_ARGUMENT` or none.
  var mentionsCivicIntegrity: Bool {
    message?.contains("CIVIC_INTEGRITY") == true
  }
}
