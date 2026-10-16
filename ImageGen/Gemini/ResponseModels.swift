import Foundation

// `generateContent` response shapes (D§2.7). Every field is optional so unexpected shapes decode
// and fall through the parser's rules instead of failing.

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
    var data: String?
  }

  var text: String?
  var inlineData: InlineData?
  var thought: Bool?
  var thoughtSignature: String?
}

struct PromptFeedback: Decodable, Sendable {
  var blockReason: String?
  var blockReasonMessage: String?
}

/// Ignored.
struct UsageMetadata: Decodable, Sendable {}
