import Foundation

// DTOs that cross milestones or layers (IMPLEMENTATION_PLAN.md section 3, Shared types rule).
// Later milestones add behavior in extensions; they never redefine or move these types.

enum Role: String, Sendable, Codable { case user, model }

enum ImageOrigin: String, Sendable, Codable { case photos, files, paste, model }

// MARK: - Settings resolution (behavior: M1 Track 1A)

/// Snapshot of `AppSettings`.
struct GenerationDefaults: Sendable, Equatable {
  var aspectRatio: AspectRatio = .r16x9
  var imageSize: ImageSize = .s2K
  var threshold: SafetyThreshold = .blockNone
  var omitCivicIntegrity = false
  /// Flipped to false by M9 task 8 if R3's 1K cap is confirmed.
  var includeTextModality = true
  /// Every catalog ID by default, plus custom IDs; always contains Flash.
  var enabledModelIDs: Set<String> = ModelCatalog.builtInIDs
  /// 1536 / 2048 / 3072 / 4096.
  var maxUploadLongEdge = 2048
}

struct ChatOverrides: Sendable, Equatable {
  var modelID: String?
  var aspectRatio: AspectRatio?
  var imageSize: ImageSize?
}

enum CoercionField: String, Sendable, Codable { case model, aspectRatio, imageSize }

struct Coercion: Sendable, Codable, Equatable {
  var field: CoercionField
  var requested: String
  /// nil: the key is omitted.
  var used: String?
  var reason: String
}

struct EffectiveSettings: Sendable, Codable, Equatable {
  var modelID: String
  var aspectRatio: AspectRatio?
  var imageSize: ImageSize?
  var threshold: SafetyThreshold
  var categories: [HarmCategory]
  var includeTextModality: Bool
  /// For the pill caution glyph; empty in recorded snapshots.
  var coercions: [Coercion]
}

// MARK: - Input selection (behavior: M1 Track 1A)

struct SelectorImage: Sendable, Equatable {
  let id: UUID
  let ordinal: Int
}

struct SelectorMessage: Sendable, Equatable {
  let sequence: Int
  let role: Role
  let replyState: RequestState?
  let images: [SelectorImage]
}

/// There is no skip-the-image flag (D§2.2).
struct SelectionInput: Sendable {
  var attachments: [UUID]
  var pinnedImageID: UUID?
  var pinnedImageExists: Bool
  var history: [SelectorMessage]
}

struct Selection: Sendable, Equatable {
  let imageIDs: [UUID]
  let reason: SelectionReason
  let clearPin: Bool
}

// MARK: - Images (behavior: M3)

struct PreparedImage: Sendable, Equatable {
  let url: URL
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let longEdgeSetting: Int
}

struct StagedAttachment: Sendable, Equatable {
  let id: UUID
  let origin: ImageOrigin
  let originalURL: URL
  let originalMimeType: String
  let originalByteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let originalFilename: String?
  let prepared: PreparedImage
}

// MARK: - Stored JSON payloads (D§4.3)

struct MessagePart: Sendable, Codable, Equatable {
  enum Kind: String, Sendable, Codable { case text, image }
  var kind: Kind
  var text: String?
  var imageID: UUID?
}

/// Describes the bytes actually sent.
struct RequestInput: Sendable, Codable, Equatable {
  var imageID: UUID
  var preparedRelativePath: String
  var mimeType: String
  var byteCount: Int
  var pixelWidth: Int
  var pixelHeight: Int
}

// MARK: - UI → GenerationService (behavior: M4)

struct SendDraft: Sendable {
  var conversationID: UUID
  var promptText: String
  /// Tray order.
  var attachments: [StagedAttachment]
  var settings: EffectiveSettings
}

// MARK: - DataStore boundary (behavior: M2)

struct SendRecordInput: Sendable {
  var conversationID: UUID
  var promptText: String
  /// Index = ordinal.
  var attachments: [StagedAttachment]
  var selection: Selection
  var settings: EffectiveSettings
  /// The Send action (D§4.13).
  var activityActionID: ActionID
}

struct SendRecord: Sendable, Equatable {
  let requestID: UUID
  let userMessageID: UUID
  let replyMessageID: UUID
}

struct InputSnapshot: Sendable, Equatable {
  let imageID: UUID
  let conversationID: UUID
  let origin: ImageOrigin
  let originalRelativePath: String
  let originalMimeType: String
  /// Uploads: the `ImageAsset.prepared*` fields; model outputs: nil.
  let prepared: RequestInput?
  let preparedLongEdgeSetting: Int?
}

struct RequestSnapshot: Sendable, Equatable {
  let id: UUID
  let conversationID: UUID
  let userMessageID: UUID?
  let replyMessageID: UUID
  let sourceRequestID: UUID?
  /// As recorded.
  let settings: EffectiveSettings
  let promptText: String
  let inputs: [RequestInput]
  let inputAssets: [InputSnapshot]
  let selectionReason: SelectionReason
  let state: RequestState
  let attempt: Int
  let maxAutoRetries: Int
  let autoRetriesUsed: Int
  let civicFallbackUsed: Bool
  let nextAttemptCreatedInBackground: Bool
  let taskIdentifier: Int?
  let nextAttemptAt: Date?
  let startedAt: Date?
  /// The action following this request (D§4.3, D§4.13).
  let activityActionID: ActionID?
}

/// nil = unchanged; for `Int??` and `Date??`, `.some(nil)` clears.
struct RequestPatch: Sendable {
  var state: RequestState?
  var attempt: Int?
  var autoRetriesUsed: Int?
  var civicFallbackUsed: Bool?
  var nextAttemptCreatedInBackground: Bool?
  var taskIdentifier: Int??
  var nextAttemptAt: Date??
  var startedAt: Date?
  var completedAt: Date?
  var categories: [HarmCategory]?
  var inputs: [RequestInput]?
  var httpStatus: Int?
  var errorStatus: String?
  var errorMessage: String?
  var details: String?
  var notices: [String]?
  var finishReason: String?
  // A refusal writes refusalReason = reason and errorMessage = finishMessage (D§2.7); a Retry clears both (D§6).
  var refusalReason: String?
  var modelVersion: String?
  var responseID: String?
  var outputWidth: Int?
  var outputHeight: Int?
  /// A manual Retry points the request at its Retry action.
  var activityActionID: ActionID?
}

// MARK: - Added in M2

/// A reply image whose file `GenerationService` has already moved into `Images/<conv>/`.
/// `completeReply` gives each one `ordinal` = its index (D§4.3).
struct ReplyImage: Sendable, Equatable {
  let id: UUID
  let relativePath: String
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

/// What a delete removed, for the Delete chat / Delete message / Delete all chats results (D§4.13).
struct DeletionResult: Sendable, Equatable {
  /// Non-terminal requests whose records were deleted; the caller cancels their tasks.
  var liveRequestIDs: [UUID] = []
  var filesRemoved = 0
  var bytesFreed: Int64 = 0
  var failures = 0
  var firstError: String?
}
