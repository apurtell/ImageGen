import Foundation
import SwiftData

/// Versioned schema definition governing application persistence entities under SwiftData.
///
/// Schema Design:
/// - Enums are stored as canonical raw string representations, while structured array payloads
///   are serialized to JSON `Data` containers exposed via computed property accessors.
/// - The domain graph centers on `Conversation`, which cascades deletions to member `Message`
///   and `GenerationRequest` entities, while `Message` cascades deletions to attached `ImageAsset` records.
/// - Cross-entity associations between requests, originating messages, and input images are mediated via UUID references.
/// - Model classes are nonisolated and non-Sendable, confined strictly to the context in which they are fetched.
///   Mutations are executed exclusively within `DataStore` background contexts, while presentation queries
///   observe snapshots via `@Query` descriptors on the main actor.
enum SchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  static var models: [any PersistentModel.Type] {
    [Conversation.self, Message.self, ImageAsset.self, GenerationRequest.self]
  }

  /// Persistent conversation entity representing a chat thread and its associated parameter overrides.
  @Model nonisolated final class Conversation {
    #Unique<Conversation>([\.id])

    var id: UUID
    var title: String
    var titleIsUserSet: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Model identifier override, or nil to inherit system default.
    var modelIDOverride: String?
    /// Aspect ratio override literal, or nil to inherit settings default.
    var aspectRatioOverride: String?
    /// Output resolution tier override, or nil to inherit settings default.
    var imageSizeOverride: String?
    /// Pinned reference image identifier for multi-turn generation context.
    var pinnedImageID: UUID?
    /// Preserved composer draft text buffer.
    var draftText: String
    var nextSequence: Int

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    @Relationship(deleteRule: .cascade, inverse: \GenerationRequest.conversation)
    var requests: [GenerationRequest] = []

    init(id: UUID = UUID(), title: String = Conversation.untitled, now: Date = Date()) {
      self.id = id
      self.title = title
      self.titleIsUserSet = false
      self.createdAt = now
      self.updatedAt = now
      self.draftText = ""
      self.nextSequence = 0
    }

    static let untitled = "New Chat"
  }

  /// Persistent message entity representing either a user prompt entry or a model response turn.
  @Model nonisolated final class Message {
    #Unique<Message>([\.id])
    #Index<Message>([\.sequence])

    var id: UUID
    /// Monotonically increasing sequence index within the enclosing conversation.
    var sequence: Int
    /// Message participant role (`user` or `model`).
    var role: String
    var createdAt: Date
    /// Raw textual prompt or accumulated response text content.
    var text: String
    /// Serialized JSON payload encoding ordered `[MessagePart]` elements.
    var partsData: Data
    /// Originating or producing generation request identifier.
    var requestID: UUID?
    /// Lineage link to an ancestor request if generated via regeneration workflows.
    var regenerateOfRequestID: UUID?
    var conversation: Conversation?

    @Relationship(deleteRule: .cascade, inverse: \ImageAsset.message)
    var images: [ImageAsset] = []

    init(id: UUID = UUID(), sequence: Int, role: Role, text: String, parts: [MessagePart], requestID: UUID?, now: Date = Date()) {
      self.id = id
      self.sequence = sequence
      self.role = role.rawValue
      self.createdAt = now
      self.text = text
      self.partsData = JSONCoding.encode(parts)
      self.requestID = requestID
    }

    var messageRole: Role { Role(rawValue: role) ?? .user }

    /// Strongly typed accessor decoding serialized message parts from underlying binary storage.
    var parts: [MessagePart] {
      get { JSONCoding.decode([MessagePart].self, from: partsData) ?? [] }
      set { partsData = JSONCoding.encode(newValue) }
    }

    var orderedImages: [ImageAsset] { images.sorted { $0.ordinal < $1.ordinal } }
  }

  /// Persistent metadata record tracking an image asset and its scaled variants.
  @Model nonisolated final class ImageAsset {
    #Unique<ImageAsset>([\.id])

    var id: UUID
    /// Ordinal index within the parent message container.
    var ordinal: Int
    /// Acquisition origin (`photos`, `files`, `paste`, or `model`).
    var origin: String
    /// Relative file path under the storage root.
    var relativePath: String
    var mimeType: String
    var byteCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var originalFilename: String?
    // Prepared preprocessed variant metadata for API submission.
    var preparedRelativePath: String?
    var preparedMimeType: String?
    var preparedByteCount: Int?
    var preparedPixelWidth: Int?
    var preparedPixelHeight: Int?
    /// Long-edge resolution threshold used during variant preprocessing.
    var preparedLongEdgeSetting: Int?
    var createdAt: Date
    var message: Message?

    init(
      id: UUID, ordinal: Int, origin: ImageOrigin, relativePath: String, mimeType: String, byteCount: Int,
      pixelWidth: Int, pixelHeight: Int, originalFilename: String? = nil, now: Date = Date()
    ) {
      self.id = id
      self.ordinal = ordinal
      self.origin = origin.rawValue
      self.relativePath = relativePath
      self.mimeType = mimeType
      self.byteCount = byteCount
      self.pixelWidth = pixelWidth
      self.pixelHeight = pixelHeight
      self.originalFilename = originalFilename
      self.createdAt = now
    }

    var imageOrigin: ImageOrigin { ImageOrigin(rawValue: origin) ?? .files }

    /// Strongly typed descriptor projecting the preprocessed variant as a request input.
    var preparedInput: RequestInput? {
      guard let path = preparedRelativePath, let mime = preparedMimeType, let bytes = preparedByteCount,
        let w = preparedPixelWidth, let h = preparedPixelHeight
      else { return nil }
      return RequestInput(imageID: id, preparedRelativePath: path, mimeType: mime, byteCount: bytes, pixelWidth: w, pixelHeight: h)
    }

    /// Atomically updates or clears the preprocessed variant metadata attributes.
    func setPrepared(_ input: RequestInput?, longEdgeSetting: Int?) {
      preparedRelativePath = input?.preparedRelativePath
      preparedMimeType = input?.mimeType
      preparedByteCount = input?.byteCount
      preparedPixelWidth = input?.pixelWidth
      preparedPixelHeight = input?.pixelHeight
      preparedLongEdgeSetting = input == nil ? nil : longEdgeSetting
    }
  }

  /// Persistent generation request tracking execution parameters, attempt progression, and outcome diagnostics.
  @Model nonisolated final class GenerationRequest {
    #Unique<GenerationRequest>([\.id])
    #Index<GenerationRequest>([\.state])

    var id: UUID
    /// Link to initiating user message, or nil for regeneration requests.
    var userMessageID: UUID?
    var replyMessageID: UUID
    /// Ancestor request identifier tracking regeneration history.
    var sourceRequestID: UUID?
    var modelID: String
    var aspectRatio: String?
    var imageSize: String?
    var safetyThreshold: String
    /// Serialized JSON array of active harm categories.
    var safetyCategoriesData: Data
    var includeTextModality: Bool
    var promptText: String
    /// Serialized JSON array of `RequestInput` descriptors.
    var inputsData: Data
    var selectionReason: String
    var state: String
    var attempt: Int
    var maxAutoRetries: Int
    var autoRetriesUsed: Int
    /// Flag indicating whether civic integrity safety filtering fallback was invoked.
    var civicFallbackUsed: Bool
    /// Indicates whether next execution attempt was scheduled from background context.
    var nextAttemptCreatedInBackground: Bool
    var taskIdentifier: Int?
    var nextAttemptAt: Date?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var httpStatus: Int?
    var errorStatus: String?
    var errorMessage: String?
    /// Diagnostic response payload snippet or error payload.
    var details: String?
    /// Serialized JSON array of parsing notice strings.
    var noticesData: Data
    var finishReason: String?
    var refusalReason: String?
    var modelVersion: String?
    var responseID: String?
    var outputWidth: Int?
    var outputHeight: Int?
    var activityActionID: String?
    var conversation: Conversation?

    init(
      id: UUID = UUID(), userMessageID: UUID?, replyMessageID: UUID, sourceRequestID: UUID?, settings: EffectiveSettings,
      promptText: String, inputs: [RequestInput], selectionReason: SelectionReason, maxAutoRetries: Int = 2,
      activityActionID: ActionID?, now: Date = Date()
    ) {
      self.id = id
      self.userMessageID = userMessageID
      self.replyMessageID = replyMessageID
      self.sourceRequestID = sourceRequestID
      self.modelID = settings.modelID
      self.aspectRatio = settings.aspectRatio?.rawValue
      self.imageSize = settings.imageSize?.rawValue
      self.safetyThreshold = settings.threshold.rawValue
      self.safetyCategoriesData = JSONCoding.encode(settings.categories.map(\.rawValue))
      self.includeTextModality = settings.includeTextModality
      self.promptText = promptText
      self.inputsData = JSONCoding.encode(inputs)
      self.selectionReason = selectionReason.rawValue
      self.state = RequestState.preparing.rawValue
      self.attempt = 0
      self.maxAutoRetries = maxAutoRetries
      self.autoRetriesUsed = 0
      self.civicFallbackUsed = false
      self.nextAttemptCreatedInBackground = false
      self.createdAt = now
      self.noticesData = JSONCoding.encode([String]())
      self.activityActionID = activityActionID?.raw
    }

    /// Strongly typed request lifecycle state accessor, defaulting unrecognized strings to failed.
    var requestState: RequestState {
      get { RequestState(rawValue: state) ?? .failed }
      set { state = newValue.rawValue }
    }

    var inputs: [RequestInput] {
      get { JSONCoding.decode([RequestInput].self, from: inputsData) ?? [] }
      set { inputsData = JSONCoding.encode(newValue) }
    }

    var categories: [HarmCategory] {
      get { (JSONCoding.decode([String].self, from: safetyCategoriesData) ?? []).compactMap(HarmCategory.init(rawValue:)) }
      set { safetyCategoriesData = JSONCoding.encode(newValue.map(\.rawValue)) }
    }

    var notices: [String] {
      get { JSONCoding.decode([String].self, from: noticesData) ?? [] }
      set { noticesData = JSONCoding.encode(newValue) }
    }

    /// Reconstructs the effective generation settings captured at request creation time.
    var recordedSettings: EffectiveSettings {
      EffectiveSettings(
        modelID: modelID, aspectRatio: aspectRatio.flatMap(AspectRatio.init(rawValue:)),
        imageSize: imageSize.flatMap(ImageSize.init(rawValue:)),
        threshold: SafetyThreshold(rawValue: safetyThreshold) ?? .blockNone, categories: categories,
        includeTextModality: includeTextModality, coercions: [])
    }
  }
}

typealias Conversation = SchemaV1.Conversation
typealias Message = SchemaV1.Message
typealias ImageAsset = SchemaV1.ImageAsset
typealias GenerationRequest = SchemaV1.GenerationRequest

/// Serialization helper providing safe encoding and decoding fallbacks for JSON-backed schema properties.
enum JSONCoding {
  static func encode<T: Encodable>(_ value: T) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    try? JSONDecoder().decode(type, from: data)
  }
}
