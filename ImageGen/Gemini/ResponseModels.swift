import Foundation

// `generateContent` response shapes (D§2.7). Every field is optional so unexpected shapes decode
// and fall through the parser's rules instead of failing.
//
// These are plain `Decodable` structs: the compiler generates the JSON decoding from the property
// names, which match the API's camelCase keys. JSON keys with no property here are ignored. Only
// `ResponseParser` reads them, and only inside one `parse` call. They are `Sendable` value types, so
// they carry no shared state.

struct GenerateContentResponse: Decodable, Sendable {
  var candidates: [Candidate]?
  var promptFeedback: PromptFeedback?
  var usageMetadata: UsageMetadata?
  var modelVersion: String?
  var responseId: String?
}

struct Candidate: Decodable, Sendable {
  var content: Content?
  var finishReason: String?
  var finishMessage: String?
  var index: Int?
}

struct Content: Decodable, Sendable {
  var parts: [Part]?
  var role: String?
}

struct Part: Decodable, Sendable {
  struct InlineData: Decodable, Sendable {
    var mimeType: String?
    /// The image as base64 text. It can be several MB.
    var data: String?
  }

  /// A part has one of `text` or `inlineData`. A part with neither is ignored (D§2.7 rule 5).
  var text: String?
  var inlineData: InlineData?
  /// `true` marks a thinking part. The parser drops these (D§2.6).
  var thought: Bool?
  /// Decoded but not used. `Redactor` removes its value from `details`.
  var thoughtSignature: String?
}

struct PromptFeedback: Decodable, Sendable {
  var blockReason: String?
  var blockReasonMessage: String?
}

/// Ignored. An empty struct decodes from any JSON object and keeps none of its fields.
struct UsageMetadata: Decodable, Sendable {}
