import Foundation

// Wire data transfer models for Gemini `generateContent` response payloads.
// Properties are optional for resilient deserialization and structured failure classification.

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
    /// Base64-encoded image data string.
    var data: String?
  }

  /// Polymorphic part payload containing textual responses or inline binary data.
  var text: String?
  var inlineData: InlineData?
  /// Flag denoting internal model thought reasoning parts.
  var thought: Bool?
  /// Opaque model thought signature string sanitized prior to persistence.
  var thoughtSignature: String?
}

struct PromptFeedback: Decodable, Sendable {
  var blockReason: String?
  var blockReasonMessage: String?
}

/// Token and quota accounting metadata.
struct UsageMetadata: Decodable, Sendable {}
