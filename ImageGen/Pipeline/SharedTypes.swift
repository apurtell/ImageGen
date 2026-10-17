import Foundation

// Data Transfer Objects bridging subsystem boundaries across the presentation, pipeline, and persistence layers.
// Implemented as immutable value types conforming to `Sendable` to facilitate safe concurrent propagation across actor domains.
// Types stored within SwiftData backing entities conform to `Codable` for JSON serialization.

enum Role: String, Sendable, Codable { case user, model }

enum ImageOrigin: String, Sendable, Codable { case photos, files, paste, model }

/// Cached generation defaults snapshot read non-isolated from user defaults across worker tasks.
struct GenerationDefaults: Sendable, Equatable {
  var aspectRatio: AspectRatio = .r16x9
  var imageSize: ImageSize = .s2K
  var threshold: SafetyThreshold = .blockNone
  var omitCivicIntegrity = false
  /// Controls whether textual output modality is requested alongside images.
  var includeTextModality = true
  /// Active model identifiers permitted for selection, including default built-ins and custom configurations.
  var enabledModelIDs: Set<String> = ModelCatalog.builtInIDs
  /// Maximum long-edge pixel bound for preprocessed upload assets.
  var maxUploadLongEdge = 2048
}

/// Conversation-specific overrides taking precedence over global defaults.
struct ChatOverrides: Sendable, Equatable {
  var modelID: String?
  var aspectRatio: AspectRatio?
  var imageSize: ImageSize?
}

enum CoercionField: String, Sendable, Codable { case model, aspectRatio, imageSize }

/// Diagnostic record documenting a configuration parameter coercion to satisfy model capabilities.
struct Coercion: Sendable, Codable, Equatable {
  var field: CoercionField
  var requested: String
  /// Coerced target value; nil indicates parameter omission.
  var used: String?
  var reason: String
}

/// Fully resolved settings committed to an outgoing request payload.
struct EffectiveSettings: Sendable, Codable, Equatable {
  var modelID: String
  var aspectRatio: AspectRatio?
  var imageSize: ImageSize?
  var threshold: SafetyThreshold
  var categories: [HarmCategory]
  var includeTextModality: Bool
  /// Diagnostic parameter coercions displayed in UI status indicators.
  var coercions: [Coercion]
}

struct SelectorImage: Sendable, Equatable {
  let id: UUID
  let ordinal: Int
}

/// Minimal message projection evaluated during input image resolution.
struct SelectorMessage: Sendable, Equatable {
  let sequence: Int
  let role: Role
  let replyState: RequestState?
  let images: [SelectorImage]
}

/// Contextual parameters evaluated by `InputSelector` to resolve candidate reference assets.
struct SelectionInput: Sendable {
  var attachments: [UUID]
  var pinnedImageID: UUID?
  var pinnedImageExists: Bool
  var history: [SelectorMessage]
}

/// Resolved reference image set and corresponding selection rationale.
struct Selection: Sendable, Equatable {
  let imageIDs: [UUID]
  let reason: SelectionReason
  let clearPin: Bool
}

/// Image asset preprocessed and sized for immediate API payload incorporation.
struct PreparedImage: Sendable, Equatable {
  let url: URL
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let longEdgeSetting: Int
}

/// Staged attachment asset containing source file references and preprocessed derivatives.
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

struct MessagePart: Sendable, Codable, Equatable {
  enum Kind: String, Sendable, Codable { case text, image }
  var kind: Kind
  var text: String?
  var imageID: UUID?
}

/// Metadata describing an image payload serialized into an outgoing request.
struct RequestInput: Sendable, Codable, Equatable {
  var imageID: UUID
  var preparedRelativePath: String
  var mimeType: String
  var byteCount: Int
  var pixelWidth: Int
  var pixelHeight: Int
}

/// Draft parameters submitted from the presentation layer to initiate generation.
struct SendDraft: Sendable {
  var conversationID: UUID
  var promptText: String
  var attachments: [StagedAttachment]
  var settings: EffectiveSettings
}

/// Atomic parameters required by `DataStore.createSend` to instantiate initial message and request entities.
struct SendRecordInput: Sendable {
  var conversationID: UUID
  var promptText: String
  var attachments: [StagedAttachment]
  var selection: Selection
  var settings: EffectiveSettings
  var activityActionID: ActionID
}

struct SendRecord: Sendable, Equatable {
  let requestID: UUID
  let userMessageID: UUID
  let replyMessageID: UUID
}

/// Immutable projection of stored image asset properties.
struct InputSnapshot: Sendable, Equatable {
  let imageID: UUID
  let conversationID: UUID
  let origin: ImageOrigin
  let originalRelativePath: String
  let originalMimeType: String
  let prepared: RequestInput?
  let preparedLongEdgeSetting: Int?
}

/// Immutable snapshot of a persisted `GenerationRequest` entity across actor boundaries.
struct RequestSnapshot: Sendable, Equatable {
  let id: UUID
  let conversationID: UUID
  let userMessageID: UUID?
  let replyMessageID: UUID
  let sourceRequestID: UUID?
  let settings: EffectiveSettings
  let promptText: String
  let inputs: [RequestInput]
  let inputAssets: [InputSnapshot]
  let selectionReason: SelectionReason
  let state: RequestState
  /// Monotonically increasing attempt sequence index.
  let attempt: Int
  let maxAutoRetries: Int
  let autoRetriesUsed: Int
  let civicFallbackUsed: Bool
  /// Indicates whether the active retry task was scheduled during background execution.
  let nextAttemptCreatedInBackground: Bool
  let taskIdentifier: Int?
  let nextAttemptAt: Date?
  let startedAt: Date?
  let activityActionID: ActionID?
}

/// Partial mutation patch applied atomically to a persistent request record.
/// Double optional properties distinguish between preserving existing values (nil) and explicitly clearing attributes (.some(nil)).
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
  var refusalReason: String?
  var modelVersion: String?
  var responseID: String?
  var outputWidth: Int?
  var outputHeight: Int?
  var activityActionID: ActionID?
  /// Instructs persistence to purge prior execution outcome fields during retry initialization.
  var clearOutcome = false
}

/// Persistent image asset generated and saved within conversation storage.
struct ReplyImage: Sendable, Equatable {
  let id: UUID
  let relativePath: String
  let mimeType: String
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

/// Aggregate deletion metrics reported by conversational purging routines.
struct DeletionResult: Sendable, Equatable {
  /// Identifiers of live requests interrupted by record deletion.
  var liveRequestIDs: [UUID] = []
  var filesRemoved = 0
  var bytesFreed: Int64 = 0
  var failures = 0
  var firstError: String?
}

/// Standardized diagnostic codes representing non-HTTP failure conditions.
enum LocalErrorStatus: String, Sendable, CaseIterable {
  case empty = "EMPTY"
  case malformed = "MALFORMED"
  case noAPIKey = "NO_API_KEY"
  case tooLarge = "TOO_LARGE"
  case inputMissing = "INPUT_MISSING"
  case diskFull = "DISK_FULL"
  case timedOut = "TIMED_OUT"
  case network = "NETWORK"
  case emptyParts = "EMPTY_PARTS"
}
