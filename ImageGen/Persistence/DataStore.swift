import Foundation
import SwiftData

enum DataStoreError: Error, Equatable {
  case conversationNotFound(UUID)
  case requestNotFound(UUID)
  case messageNotFound(UUID)
}

/// What the Janitor needs from the store (D§4.4).
/// An upload of a user message, as Edit & Resend clones it (M6).
struct UploadSource: Sendable, Equatable {
  let snapshot: InputSnapshot
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let originalFilename: String?
}

struct JanitorSnapshot: Sendable {
  struct RequestInfo: Sendable {
    let isTerminal: Bool
    /// `completedAt`, else `createdAt`.
    let finishedOrCreatedAt: Date
  }

  /// Every `relativePath` and `preparedRelativePath` of an `ImageAsset`, and every
  /// `RequestInput.preparedRelativePath`.
  let referencedPaths: Set<String>
  let requests: [UUID: RequestInfo]
}

/// All background writes to SwiftData (D§5). Its API takes and returns UUIDs and Sendable snapshots;
/// model objects never leave the actor. It conforms to `ModelActor` by hand rather than through
/// `@ModelActor`, because the macro's generated initializer can't also take the `FileStore`.
actor DataStore: ModelActor {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer
  private let files: FileStore
  private let clock: @Sendable () -> Date

  init(container: ModelContainer, files: FileStore, clock: @escaping @Sendable () -> Date = { Date() }) {
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
    self.modelContainer = container
    self.files = files
    self.clock = clock
  }

  // MARK: Conversations

  func createConversation() throws -> UUID {
    let conversation = Conversation(now: clock())
    modelContext.insert(conversation)
    try modelContext.save()
    return conversation.id
  }

  /// An empty or whitespace name reverts to the automatic title.
  func rename(_ id: UUID, to name: String) throws {
    let conversation = try fetchConversation(id)
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      conversation.titleIsUserSet = false
      let firstPrompt = conversation.messages
        .filter { $0.messageRole == .user && !$0.text.isEmpty }
        .min { $0.sequence < $1.sequence }?.text
      conversation.title = firstPrompt.map(Self.automaticTitle) ?? Conversation.untitled
    } else {
      conversation.titleIsUserSet = true
      conversation.title = trimmed
    }
    try modelContext.save()
  }

  /// The first 48 characters of the prompt, cut at a word boundary (D§3.3).
  static func automaticTitle(_ prompt: String) -> String {
    let flat = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard flat.count > 48 else { return flat.isEmpty ? Conversation.untitled : flat }
    let head = String(flat.prefix(48))
    let nextIsSpace = flat.dropFirst(48).first?.isWhitespace ?? true
    if !nextIsSpace, let space = head.lastIndex(where: \.isWhitespace), space > head.startIndex {
      return String(head[..<space]).trimmingCharacters(in: .whitespaces)
    }
    return head.trimmingCharacters(in: .whitespaces)
  }

  /// Deletes the chat, its images and its request folders. The caller cancels `liveRequestIDs`.
  func deleteConversation(_ id: UUID) throws -> DeletionResult {
    let conversation = try fetchConversation(id)
    let live = conversation.requests.filter { $0.requestState.isLive }.map(\.id)
    let requestIDs = conversation.requests.map(\.id)
    modelContext.delete(conversation)
    try modelContext.save()
    var result = files.removeConversationFiles(id, requestIDs: requestIDs)
    result.liveRequestIDs = live
    return result
  }

  func messageCount(conv id: UUID) throws -> Int {
    try fetchConversation(id).messages.count
  }

  /// Deletes a chat with no messages; returns whether it did.
  @discardableResult
  func deleteIfEmpty(_ id: UUID) throws -> Bool {
    guard let conversation = try? fetchConversation(id), conversation.messages.isEmpty else { return false }
    _ = try deleteConversation(id)
    return true
  }

  func setPin(_ id: UUID, imageID: UUID?) throws {
    try fetchConversation(id).pinnedImageID = imageID
    try modelContext.save()
  }

  func setOverrides(_ id: UUID, _ overrides: ChatOverrides) throws {
    let conversation = try fetchConversation(id)
    conversation.modelIDOverride = overrides.modelID
    conversation.aspectRatioOverride = overrides.aspectRatio?.rawValue
    conversation.imageSizeOverride = overrides.imageSize?.rawValue
    try modelContext.save()
  }

  func overrides(_ id: UUID) throws -> ChatOverrides {
    let c = try fetchConversation(id)
    return ChatOverrides(
      modelID: c.modelIDOverride, aspectRatio: c.aspectRatioOverride.flatMap(AspectRatio.init(rawValue:)),
      imageSize: c.imageSizeOverride.flatMap(ImageSize.init(rawValue:)))
  }

  func setDraft(_ id: UUID, text: String) throws {
    try fetchConversation(id).draftText = text
    try modelContext.save()
  }

  func pinState(conv id: UUID) throws -> (id: UUID?, exists: Bool) {
    guard let pin = try fetchConversation(id).pinnedImageID else { return (nil, false) }
    return (pin, try fetchAsset(pin) != nil)
  }

  // MARK: Sends

  /// Records a send: the user message and its images (staged files moved into `Images/<conv>/`),
  /// the reply placeholder and the request (D§4.3).
  func createSend(_ draft: SendRecordInput) throws -> SendRecord {
    let conversation = try fetchConversation(draft.conversationID)
    let now = clock()
    let conv = conversation.id
    let requestID = UUID()

    // Move the staged files first; a failure leaves no records (the Janitor removes moved orphans).
    var assets: [ImageAsset] = []
    for (ordinal, a) in draft.attachments.enumerated() {
      let ext = Self.fileExtension(of: a.originalURL, mimeType: a.originalMimeType)
      let original = files.imageRelativePath(conv: conv, image: a.id, ext: ext)
      try files.moveStaged(a.originalURL, to: files.url(relative: original))
      let p = a.prepared
      let preparedPath = files.preparedRelativePath(
        conv: conv, image: a.id, edge: p.longEdgeSetting, ext: Self.fileExtension(of: p.url, mimeType: p.mimeType))
      try files.moveStaged(p.url, to: files.url(relative: preparedPath))

      let asset = ImageAsset(
        id: a.id, ordinal: ordinal, origin: a.origin, relativePath: original, mimeType: a.originalMimeType,
        byteCount: a.originalByteCount, pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight,
        originalFilename: a.originalFilename, now: now)
      asset.setPrepared(
        RequestInput(
          imageID: a.id, preparedRelativePath: preparedPath, mimeType: p.mimeType, byteCount: p.byteCount,
          pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight),
        longEdgeSetting: p.longEdgeSetting)
      assets.append(asset)
    }

    // Inputs: the attachments' prepared files, or the reused image as it stands now
    // (RequestPreparer, M4, settles the final RequestInputs through updateRequest).
    let inputs: [RequestInput]
    switch draft.selection.reason {
    case .attachments:
      inputs = assets.compactMap(\.preparedInput)
    case .pinned, .latest:
      inputs = try draft.selection.imageIDs.compactMap { id in try fetchAsset(id).map(Self.currentInput) }
    case .noImage:
      inputs = []
    }

    let sequence = conversation.nextSequence
    var parts = assets.map { MessagePart(kind: .image, text: nil, imageID: $0.id) }
    if !draft.promptText.isEmpty { parts.append(MessagePart(kind: .text, text: draft.promptText, imageID: nil)) }
    let user = Message(sequence: sequence, role: .user, text: draft.promptText, parts: parts, requestID: requestID, now: now)
    let reply = Message(sequence: sequence + 1, role: .model, text: "", parts: [], requestID: requestID, now: now)
    let request = GenerationRequest(
      id: requestID, userMessageID: user.id, replyMessageID: reply.id, sourceRequestID: nil, settings: draft.settings,
      promptText: draft.promptText, inputs: inputs, selectionReason: draft.selection.reason,
      activityActionID: draft.activityActionID, now: now)

    modelContext.insert(user)
    modelContext.insert(reply)
    modelContext.insert(request)
    for asset in assets {
      modelContext.insert(asset)
      asset.message = user
    }
    user.conversation = conversation
    reply.conversation = conversation
    request.conversation = conversation

    if draft.selection.clearPin { conversation.pinnedImageID = nil }
    if !conversation.titleIsUserSet && conversation.title == Conversation.untitled && !draft.promptText.isEmpty {
      conversation.title = Self.automaticTitle(draft.promptText)
    }
    conversation.nextSequence = sequence + 2
    conversation.updatedAt = now
    try modelContext.save()
    return SendRecord(requestID: requestID, userMessageID: user.id, replyMessageID: reply.id)
  }

  /// Updates an upload's prepared file after `RequestPreparer` re-prepares it (D§4.3).
  func setPreparedFile(imageID: UUID, _ prepared: RequestInput, longEdgeSetting: Int) throws {
    guard let asset = try fetchAsset(imageID) else { throw DataStoreError.messageNotFound(imageID) }
    asset.setPrepared(prepared, longEdgeSetting: longEdgeSetting)
    try modelContext.save()
  }

  /// A new reply from a request's recorded settings and inputs, verbatim (D§6). nil if any input
  /// file is missing.
  func createRegenerate(sourceRequestID: UUID, activityActionID: ActionID) throws -> SendRecord? {
    guard let source = try fetchRequest(sourceRequestID), let conversation = source.conversation else {
      throw DataStoreError.requestNotFound(sourceRequestID)
    }
    let inputs = source.inputs
    guard inputs.allSatisfy({ files.exists(relative: $0.preparedRelativePath) }) else { return nil }

    let now = clock()
    let requestID = UUID()
    let reply = Message(
      sequence: conversation.nextSequence, role: .model, text: "", parts: [], requestID: requestID, now: now)
    reply.regenerateOfRequestID = source.id
    let request = GenerationRequest(
      id: requestID, userMessageID: nil, replyMessageID: reply.id, sourceRequestID: source.id,
      settings: source.recordedSettings, promptText: source.promptText, inputs: inputs,
      selectionReason: SelectionReason(rawValue: source.selectionReason) ?? .noImage,
      maxAutoRetries: source.maxAutoRetries, activityActionID: activityActionID, now: now)
    modelContext.insert(reply)
    modelContext.insert(request)
    reply.conversation = conversation
    request.conversation = conversation
    conversation.nextSequence += 1
    conversation.updatedAt = now
    try modelContext.save()
    return SendRecord(requestID: requestID, userMessageID: try originalUserMessageID(of: source), replyMessageID: reply.id)
  }

  // MARK: Requests

  func requestSnapshot(_ id: UUID) throws -> RequestSnapshot? {
    guard let r = try fetchRequest(id) else { return nil }
    return try snapshot(r)
  }

  /// Applies the fields the closure sets; nil fields are unchanged.
  func updateRequest(_ id: UUID, _ mutate: @Sendable (inout RequestPatch) -> Void) throws {
    guard let r = try fetchRequest(id) else { throw DataStoreError.requestNotFound(id) }
    var patch = RequestPatch()
    mutate(&patch)
    apply(patch, to: r)
    try modelContext.save()
  }

  func nonTerminalRequests() throws -> [RequestSnapshot] {
    let live = RequestState.allCases.filter(\.isLive).map(\.rawValue)
    let requests = try modelContext.fetch(
      FetchDescriptor<GenerationRequest>(
        predicate: #Predicate { live.contains($0.state) }, sortBy: [SortDescriptor(\.createdAt)]))
    return try requests.map(snapshot)
  }

  /// Fills the reply: its parts, its images (ordinal = index among the image parts, D§4.3), the
  /// request's notices and outcome fields.
  func completeReply(
    requestID: UUID, parts: [MessagePart], images: [ReplyImage], notices: [String], outcomeFields: RequestPatch
  ) throws {
    guard let request = try fetchRequest(requestID) else { throw DataStoreError.requestNotFound(requestID) }
    guard let reply = try fetchMessage(request.replyMessageID) else {
      throw DataStoreError.messageNotFound(request.replyMessageID)
    }
    let now = clock()
    for (ordinal, image) in images.enumerated() {
      let asset = ImageAsset(
        id: image.id, ordinal: ordinal, origin: .model, relativePath: image.relativePath, mimeType: image.mimeType,
        byteCount: image.byteCount, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight, now: now)
      modelContext.insert(asset)
      asset.message = reply
    }
    reply.parts = parts
    reply.text = parts.compactMap { $0.kind == .text ? $0.text : nil }.joined(separator: "\n\n")
    apply(outcomeFields, to: request)
    request.notices = notices
    request.conversation?.updatedAt = now
    try modelContext.save()
  }

  // MARK: Selection

  /// The chat's messages for `InputSelector`, by ascending sequence; a model message carries its
  /// request's state.
  func selectorHistory(conv id: UUID) throws -> [SelectorMessage] {
    let conversation = try fetchConversation(id)
    let states = Dictionary(conversation.requests.map { ($0.id, $0.requestState) }, uniquingKeysWith: { a, _ in a })
    return conversation.messages.sorted { $0.sequence < $1.sequence }.map { m in
      SelectorMessage(
        sequence: m.sequence, role: m.messageRole, replyState: m.requestID.flatMap { states[$0] },
        images: m.orderedImages.map { SelectorImage(id: $0.id, ordinal: $0.ordinal) })
    }
  }

  /// A message's images in ordinal order (Edit & Resend clones them, M6).
  func imageSnapshots(messageID: UUID) throws -> [InputSnapshot] {
    guard let message = try fetchMessage(messageID) else { throw DataStoreError.messageNotFound(messageID) }
    let conv = message.conversation?.id ?? UUID()
    return message.orderedImages.map { Self.inputSnapshot($0, conversationID: conv) }
  }

  /// A user message's uploads in ordinal order, with what a tray item needs (Edit & Resend, M6).
  func uploadSources(messageID: UUID) throws -> [UploadSource] {
    guard let message = try fetchMessage(messageID) else { throw DataStoreError.messageNotFound(messageID) }
    let conv = message.conversation?.id ?? UUID()
    return message.orderedImages.filter { $0.imageOrigin != .model }.map {
      UploadSource(
        snapshot: Self.inputSnapshot($0, conversationID: conv), byteCount: $0.byteCount, pixelWidth: $0.pixelWidth,
        pixelHeight: $0.pixelHeight, originalFilename: $0.originalFilename)
    }
  }

  /// Snapshots of the given images, in the given order; missing ones are skipped.
  func inputSnapshots(_ imageIDs: [UUID]) throws -> [InputSnapshot] {
    try imageIDs.compactMap { id in
      try fetchAsset(id).map { Self.inputSnapshot($0, conversationID: $0.message?.conversation?.id ?? UUID()) }
    }
  }

  /// The chat's title, for notifications.
  func conversationTitle(_ id: UUID) throws -> String {
    try fetchConversation(id).title
  }

  /// Whether the chat has a request that isn't terminal (one in flight per chat, D§4.6).
  func hasLiveRequest(conv id: UUID) throws -> Bool {
    try fetchConversation(id).requests.contains { $0.requestState.isLive }
  }

  /// The stored outcome fields of a request (for the service's logging and the tests).
  struct OutcomeFields: Sendable, Equatable {
    var httpStatus: Int?
    var errorStatus: String?
    var errorMessage: String?
    var details: String?
    var notices: [String]
    var finishReason: String?
    var refusalReason: String?
    var outputWidth: Int?
    var outputHeight: Int?
  }

  func outcomeFields(_ id: UUID) throws -> OutcomeFields? {
    guard let r = try fetchRequest(id) else { return nil }
    return OutcomeFields(
      httpStatus: r.httpStatus, errorStatus: r.errorStatus, errorMessage: r.errorMessage, details: r.details,
      notices: r.notices, finishReason: r.finishReason, refusalReason: r.refusalReason, outputWidth: r.outputWidth,
      outputHeight: r.outputHeight)
  }

  /// A message's parts (to check a reply).
  func messageParts(_ id: UUID) throws -> [MessagePart]? {
    try fetchMessage(id)?.parts
  }

  /// The chat's request that isn't terminal, if any.
  func liveRequest(conv id: UUID) throws -> RequestSnapshot? {
    guard let r = try fetchConversation(id).requests.first(where: { $0.requestState.isLive }) else { return nil }
    return try snapshot(r)
  }

  /// The user message a request came from, following regenerate lineage; nil if it was deleted.
  func originatingUserMessage(requestID: UUID) throws -> (id: UUID, text: String)? {
    guard let request = try fetchRequest(requestID) else { return nil }
    let userID = try originalUserMessageID(of: request)
    guard let message = try fetchMessage(userID), message.messageRole == .user else { return nil }
    return (message.id, message.text)
  }

  func draftText(conv id: UUID) throws -> String {
    try fetchConversation(id).draftText
  }

  /// A message's text and the request it belongs to.
  func messageInfo(_ id: UUID) throws -> (text: String, role: Role, requestID: UUID?)? {
    guard let m = try fetchMessage(id) else { return nil }
    return (m.text, m.messageRole, m.requestID)
  }

  /// The original file of an image, and its conversation.
  func imageFile(_ id: UUID) throws -> (relativePath: String, mimeType: String, width: Int, height: Int)? {
    guard let a = try fetchAsset(id) else { return nil }
    return (a.relativePath, a.mimeType, a.pixelWidth, a.pixelHeight)
  }

  /// Number of images in a chat (for the delete confirmation).
  func imageCount(conv id: UUID) throws -> Int {
    try fetchConversation(id).messages.reduce(0) { $0 + $1.images.count }
  }

  // MARK: Deletion

  /// Deletes one message and its image files. Deleting a user message keeps its replies; deleting
  /// a reply also deletes the request that produced it.
  func deleteMessage(_ id: UUID) throws -> DeletionResult {
    guard let message = try fetchMessage(id) else { throw DataStoreError.messageNotFound(id) }
    var result = DeletionResult()
    var paths = message.images.flatMap { [$0.relativePath, $0.preparedRelativePath].compactMap { $0 } }
    var requestDirs: [UUID] = []
    if message.messageRole == .model {
      let replyID = message.id
      let requests = try modelContext.fetch(
        FetchDescriptor<GenerationRequest>(predicate: #Predicate { $0.replyMessageID == replyID }))
      for r in requests {
        if r.requestState.isLive { result.liveRequestIDs.append(r.id) }
        requestDirs.append(r.id)
        modelContext.delete(r)
      }
    }
    message.conversation?.updatedAt = clock()
    modelContext.delete(message)
    try modelContext.save()
    paths = Array(Set(paths))
    for path in paths { files.remove(files.url(relative: path), into: &result) }
    for r in requestDirs { files.remove(files.requestDir(r), into: &result) }
    return result
  }

  /// How many chats and images there are (Delete All Chats states them).
  func inventory() throws -> (chats: Int, images: Int) {
    (try modelContext.fetchCount(FetchDescriptor<Conversation>()), try modelContext.fetchCount(FetchDescriptor<ImageAsset>()))
  }

  func deleteAll() throws -> DeletionResult {
    var total = DeletionResult()
    for conversation in try modelContext.fetch(FetchDescriptor<Conversation>()) {
      let r = try deleteConversation(conversation.id)
      total.liveRequestIDs += r.liveRequestIDs
      total.filesRemoved += r.filesRemoved
      total.bytesFreed += r.bytesFreed
      total.failures += r.failures
      total.firstError = total.firstError ?? r.firstError
    }
    return total
  }

  // MARK: Janitor

  func janitorSnapshot() throws -> JanitorSnapshot {
    var paths = Set<String>()
    for asset in try modelContext.fetch(FetchDescriptor<ImageAsset>()) {
      paths.insert(asset.relativePath)
      if let p = asset.preparedRelativePath { paths.insert(p) }
    }
    var requests: [UUID: JanitorSnapshot.RequestInfo] = [:]
    for r in try modelContext.fetch(FetchDescriptor<GenerationRequest>()) {
      for input in r.inputs { paths.insert(input.preparedRelativePath) }
      requests[r.id] = .init(isTerminal: r.requestState.isTerminal, finishedOrCreatedAt: r.completedAt ?? r.createdAt)
    }
    return JanitorSnapshot(referencedPaths: paths, requests: requests)
  }

  // MARK: Helpers

  private func fetchConversation(_ id: UUID) throws -> Conversation {
    var d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    guard let c = try modelContext.fetch(d).first else { throw DataStoreError.conversationNotFound(id) }
    return c
  }

  private func fetchMessage(_ id: UUID) throws -> Message? {
    var d = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try modelContext.fetch(d).first
  }

  private func fetchAsset(_ id: UUID) throws -> ImageAsset? {
    var d = FetchDescriptor<ImageAsset>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try modelContext.fetch(d).first
  }

  private func fetchRequest(_ id: UUID) throws -> GenerationRequest? {
    var d = FetchDescriptor<GenerationRequest>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    return try modelContext.fetch(d).first
  }

  /// Follows regenerate lineage back to the send that had a user message.
  private func originalUserMessageID(of request: GenerationRequest) throws -> UUID {
    var current: GenerationRequest? = request
    var hops = 0
    while let r = current, hops < 1000 {
      if let user = r.userMessageID { return user }
      current = try r.sourceRequestID.flatMap(fetchRequest)
      hops += 1
    }
    return request.replyMessageID
  }

  private func snapshot(_ r: GenerationRequest) throws -> RequestSnapshot {
    let conv = r.conversation?.id ?? UUID()
    let assets = try r.inputs.compactMap { try fetchAsset($0.imageID) }.map { Self.inputSnapshot($0, conversationID: conv) }
    return RequestSnapshot(
      id: r.id, conversationID: conv, userMessageID: r.userMessageID, replyMessageID: r.replyMessageID,
      sourceRequestID: r.sourceRequestID, settings: r.recordedSettings, promptText: r.promptText, inputs: r.inputs,
      inputAssets: assets, selectionReason: SelectionReason(rawValue: r.selectionReason) ?? .noImage,
      state: r.requestState, attempt: r.attempt, maxAutoRetries: r.maxAutoRetries, autoRetriesUsed: r.autoRetriesUsed,
      civicFallbackUsed: r.civicFallbackUsed, nextAttemptCreatedInBackground: r.nextAttemptCreatedInBackground,
      taskIdentifier: r.taskIdentifier, nextAttemptAt: r.nextAttemptAt, startedAt: r.startedAt,
      activityActionID: r.activityActionID.map { ActionID(raw: $0) })
  }

  private static func inputSnapshot(_ a: ImageAsset, conversationID: UUID) -> InputSnapshot {
    InputSnapshot(
      imageID: a.id, conversationID: conversationID, origin: a.imageOrigin, originalRelativePath: a.relativePath,
      originalMimeType: a.mimeType, prepared: a.preparedInput, preparedLongEdgeSetting: a.preparedLongEdgeSetting)
  }

  /// An upload's prepared file, or a model output's original bytes.
  private static func currentInput(_ a: ImageAsset) -> RequestInput {
    a.preparedInput
      ?? RequestInput(
        imageID: a.id, preparedRelativePath: a.relativePath, mimeType: a.mimeType, byteCount: a.byteCount,
        pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight)
  }

  private static func fileExtension(of url: URL, mimeType: String) -> String {
    url.pathExtension.isEmpty ? MimeTypes.fileExtension(for: mimeType) : url.pathExtension.lowercased()
  }

  private func apply(_ p: RequestPatch, to r: GenerationRequest) {
    if p.clearOutcome {
      r.httpStatus = nil
      r.errorStatus = nil
      r.errorMessage = nil
      r.details = nil
      r.notices = []
      r.finishReason = nil
      r.refusalReason = nil
      r.modelVersion = nil
      r.responseID = nil
      r.outputWidth = nil
      r.outputHeight = nil
      r.completedAt = nil
    }
    if let v = p.state { r.requestState = v }
    if let v = p.attempt { r.attempt = v }
    if let v = p.autoRetriesUsed { r.autoRetriesUsed = v }
    if let v = p.civicFallbackUsed { r.civicFallbackUsed = v }
    if let v = p.nextAttemptCreatedInBackground { r.nextAttemptCreatedInBackground = v }
    if let v = p.taskIdentifier { r.taskIdentifier = v }
    if let v = p.nextAttemptAt { r.nextAttemptAt = v }
    if let v = p.startedAt { r.startedAt = v }
    if let v = p.completedAt { r.completedAt = v }
    if let v = p.categories { r.categories = v }
    if let v = p.inputs { r.inputs = v }
    if let v = p.httpStatus { r.httpStatus = v }
    if let v = p.errorStatus { r.errorStatus = v }
    if let v = p.errorMessage { r.errorMessage = v }
    if let v = p.details { r.details = v }
    if let v = p.notices { r.notices = v }
    if let v = p.finishReason { r.finishReason = v }
    if let v = p.refusalReason { r.refusalReason = v }
    if let v = p.modelVersion { r.modelVersion = v }
    if let v = p.responseID { r.responseID = v }
    if let v = p.outputWidth { r.outputWidth = v }
    if let v = p.outputHeight { r.outputHeight = v }
    if let v = p.activityActionID { r.activityActionID = v.raw }
  }
}
