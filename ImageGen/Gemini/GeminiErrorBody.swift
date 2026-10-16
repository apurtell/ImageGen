import Foundation

/// Any JSON value, for the open-ended `error.details` entries.
enum AnyJSON: Sendable, Equatable, Decodable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([AnyJSON])
  case object([String: AnyJSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([AnyJSON].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: AnyJSON].self))
    }
  }

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
struct GeminiErrorBody: Sendable, Equatable, Decodable {
  var code: Int?
  var message: String?
  var status: String?
  var details: [AnyJSON]

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
    try? JSONDecoder().decode(GeminiErrorBody.self, from: data)
  }

  /// `google.rpc.RetryInfo.retryDelay`, for example `"30s"` or `"1.5s"`.
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

  /// The deprecated-category rejection that triggers the CIVIC fallback (D§2.4).
  var mentionsCivicIntegrity: Bool {
    message?.contains("CIVIC_INTEGRITY") == true
  }
}
