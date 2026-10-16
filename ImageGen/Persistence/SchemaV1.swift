import Foundation
import SwiftData

/// The SwiftData schema (D§4.3). Enums are stored as raw `String`s and ordered or structured
/// payloads as JSON `Data`, wrapped by typed accessors.
enum SchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

  static var models: [any PersistentModel.Type] {
    [Conversation.self, Message.self, ImageAsset.self, GenerationRequest.self]
  }

  @Model nonisolated final class Conversation {
    #Unique<Conversation>([\.id])

    var id: UUID
    var title: String
    var titleIsUserSet: Bool
    var createdAt: Date
    var updatedAt: Date
    /// nil = default (Flash).
    var modelIDOverride: String?
    /// nil = Settings default.
    var aspectRatioOverride: String?
    /// nil = Settings default.
    var imageSizeOverride: String?
    var pinnedImageID: UUID?
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

  @Model nonisolated final class Message {
    #Unique<Message>([\.id])
    #Index<Message>([\.sequence])

    var id: UUID
    /// Monotonic per chat.
    var sequence: Int
    /// `user` or `model`.
    var role: String
    var createdAt: Date
    /// The prompt (user); for a model reply, its text runs joined by a blank line (Copy Text).
    var text: String
    /// JSON `[MessagePart]`: the order of text and image parts.
    var partsData: Data
    /// User: the request it started. Model: the request that produced it.
    var requestID: UUID?
    /// Model only.
    var regenerateOfRequestID: UUID?
    var conversation: Conversation?

    /// Unordered in SwiftData; read through `orderedImages`.
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

    var parts: [MessagePart] {
      get { JSONCoding.decode([MessagePart].self, from: partsData) ?? [] }
      set { partsData = JSONCoding.encode(newValue) }
    }

    var orderedImages: [ImageAsset] { images.sorted { $0.ordinal < $1.ordinal } }
  }

  @Model nonisolated final class ImageAsset {
    #Unique<ImageAsset>([\.id])

    var id: UUID
    /// 0-based position within its message, assigned once (D§4.3).
    var ordinal: Int
    /// `photos`, `files`, `paste` or `model`.
    var origin: String
    /// `Images/<conv>/<id>.<ext>`.
    var relativePath: String
    var mimeType: String
    var byteCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var originalFilename: String?
    // Uploads only: the API-ready file (D§4.3, D§4.8).
    var preparedRelativePath: String?
    var preparedMimeType: String?
    var preparedByteCount: Int?
    var preparedPixelWidth: Int?
    var preparedPixelHeight: Int?
    /// The `maxUploadLongEdge` the prepared file was made at.
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

    /// The prepared file as a `RequestInput`, when there is one.
    var preparedInput: RequestInput? {
      guard let path = preparedRelativePath, let mime = preparedMimeType, let bytes = preparedByteCount,
        let w = preparedPixelWidth, let h = preparedPixelHeight
      else { return nil }
      return RequestInput(imageID: id, preparedRelativePath: path, mimeType: mime, byteCount: bytes, pixelWidth: w, pixelHeight: h)
    }

    func setPrepared(_ input: RequestInput?, longEdgeSetting: Int?) {
      preparedRelativePath = input?.preparedRelativePath
      preparedMimeType = input?.mimeType
      preparedByteCount = input?.byteCount
      preparedPixelWidth = input?.pixelWidth
      preparedPixelHeight = input?.pixelHeight
      preparedLongEdgeSetting = input == nil ? nil : longEdgeSetting
    }
  }

  @Model nonisolated final class GenerationRequest {
    #Unique<GenerationRequest>([\.id])
    #Index<GenerationRequest>([\.state])

    var id: UUID
    /// nil for a regenerate.
    var userMessageID: UUID?
    var replyMessageID: UUID
    /// Regenerate lineage.
    var sourceRequestID: UUID?
    var modelID: String
    /// The value sent; nil if the key was omitted.
    var aspectRatio: String?
    /// The value sent; nil if the key was omitted.
    var imageSize: String?
    var safetyThreshold: String
    /// JSON `[String]`: the categories actually sent.
    var safetyCategoriesData: Data
    var includeTextModality: Bool
    var promptText: String
    /// JSON `[RequestInput]`.
    var inputsData: Data
    /// `attachments`, `pinned`, `latest` or `none`.
    var selectionReason: String
    var state: String
    /// Every attempt, automatic or manual.
    var attempt: Int
    var maxAutoRetries: Int
    /// Reset to 0 by a manual Retry.
    var autoRetriesUsed: Int
    /// The CIVIC rebuild was done for this request.
    var civicFallbackUsed: Bool
    /// A `retryScheduled` task created while inactive.
    var nextAttemptCreatedInBackground: Bool
    var taskIdentifier: Int?
    var nextAttemptAt: Date?
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var httpStatus: Int?
    /// For example `RESOURCE_EXHAUSTED`.
    var errorStatus: String?
    /// The API error message, or `finishMessage` for a refusal.
    var errorMessage: String?
    /// Redacted JSON or error body, at most 64 KB.
    var details: String?
    /// JSON `[String]`: parser notices.
    var noticesData: Data
    var finishReason: String?
    /// `promptFeedback.blockReason` or the refusing `finishReason`.
    var refusalReason: String?
    var modelVersion: String?
    var responseID: String?
    var outputWidth: Int?
    var outputHeight: Int?
    /// Logging only: the action following this request (D§4.13).
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

    /// The settings as recorded; recorded snapshots carry no coercions.
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

/// JSON for the stored payloads. Encoding these value types can't fail.
enum JSONCoding {
  static func encode<T: Encodable>(_ value: T) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    try? JSONDecoder().decode(type, from: data)
  }
}
