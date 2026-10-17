import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Provenance classification indicating how an input image was ingested into the composer pipeline.
enum AttachSource: String, Sendable {
  case photos = "Photos"
  case files = "Files"
  case paste = "Paste"

  var origin: ImageOrigin {
    switch self {
    case .photos: .photos
    case .files: .files
    case .paste: .paste
    }
  }
}

// Manages candidate ingestion, asynchronous pre-processing, staging storage lifecycle,
// and state synchronization for composer attachments.
//
// Concurrency Model:
// Executes within the main-actor context of ChatScreenModel. Heavy image decoding,
// downsampling, and filesystem I/O operations are offloaded to cooperative detached tasks
// or background worker routines. The in-memory tray collection remains the authoritative state;
// asynchronous completion routines verify item identity against the active tray to handle
// concurrent user dismissals, re-ordering, or immediate submission.

/// Staging candidate encapsulating raw input payloads awaiting file-backed persistence.
struct AttachmentCandidate: Sendable {
  var filename: String?
  /// Asynchronous staging routine writing raw source bytes into the sandbox staging directory.
  var stage: @Sendable (_ stagingDir: URL, _ id: UUID) async throws -> URL

  /// Constructs a staging candidate from in-memory byte buffers.
  static func data(_ data: Data, filename: String? = nil, preferredExtension: String? = nil) -> AttachmentCandidate {
    AttachmentCandidate(filename: filename) { dir, id in
      try AttachmentStaging.write(data, into: dir, id: id, preferredExtension: preferredExtension)
    }
  }

  /// Constructs a staging candidate from a security-scoped filesystem URL.
  static func file(_ url: URL) -> AttachmentCandidate {
    AttachmentCandidate(filename: url.lastPathComponent) { dir, id in
      try FileImport.copySecurityScoped(url, into: dir, id: id)
    }
  }
}

/// Staging utility responsible for persisting incoming candidate data into the staging directory.
enum AttachmentStaging {
  /// Writes input data to a unique staged file, deriving file format extensions from image headers.
  static func write(_ data: Data, into dir: URL, id: UUID, preferredExtension: String? = nil) throws -> URL {
    guard let source = CGImageSourceCreateWithData(data as CFData, ImageInspector.noCache),
      let type = CGImageSourceGetType(source) as String?
    else { throw UnsupportedImageError() }
    let ext = UTType(type)?.preferredFilenameExtension ?? preferredExtension ?? "img"
    let url = dir.appendingPathComponent("\(id.uuidString).\(ext)")
    try FileStore.createDirectory(dir)
    try data.write(to: url)
    return url
  }
}

/// Represents the presentation and processing lifecycle state of an attachment within the composer tray.
struct TrayItem: Identifiable, Equatable, Sendable {
  /// Sequential processing states of an attachment item during ingestion.
  enum State: Equatable, Sendable {
    case importing
    case preparing
    case ready(PreparedImage)
    case failed(String)
  }

  let id: UUID
  let origin: ImageOrigin
  var state: State
  /// File URL of the staged original image once ingestion succeeds.
  var originalURL: URL?
  var originalMimeType = ""
  var originalByteCount = 0
  /// Dimensions adjusted for display orientation.
  var pixelWidth = 0
  var pixelHeight = 0
  var originalFilename: String?

  var isPending: Bool { state == .importing || state == .preparing }
  var failure: String? { if case .failed(let reason) = state { reason } else { nil } }
  var prepared: PreparedImage? { if case .ready(let p) = state { p } else { nil } }

  var stateName: String {
    switch state {
    case .importing: "importing"
    case .preparing: "preparing"
    case .ready: "ready"
    case .failed: "failed"
    }
  }

  /// Converts the fully prepared tray item into a staged submission payload.
  var staged: StagedAttachment? {
    guard let prepared, let originalURL else { return nil }
    return StagedAttachment(
      id: id, origin: origin, originalURL: originalURL, originalMimeType: originalMimeType,
      originalByteCount: originalByteCount, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      originalFilename: originalFilename, prepared: prepared)
  }
}

/// Terminal disposition of an individual tray item processing pipeline.
enum TrayItemOutcome: Sendable, Equatable {
  case prepared
  case reused
  case importFailed(String)
  case prepareFailed(String)
  case removed
}

/// Attachment lifecycle coordination and draft logic for ChatScreenModel.
extension ChatScreenModel {
  /// Global capacity limit for input image attachments per prompt submission.
  static let maxAttachments = 14
  static let fullTrayHint = "Up to 14 images per message"

  /// Ready, pending (importing or preparing) and failed items: the inputs to `canSend` and the caption.
  var trayCounts: TrayCounts {
    TrayCounts(
      ready: tray.count(where: { $0.prepared != nil }), pending: tray.count(where: \.isPending),
      failed: tray.count(where: { $0.failure != nil }))
  }

  var canAddAttachments: Bool { tray.count < Self.maxAttachments }

  /// Computes the remaining attachment selection allowance for system pickers.
  static func pickerLimit(trayCount: Int) -> Int { max(1, maxAttachments - trayCount) }
  var pickerLimit: Int { Self.pickerLimit(trayCount: tray.count) }

  /// Estimated wire transmission payload size computed from active tray attachments and current parameters.
  var projectedBodyBytes: Int {
    let images = tray.compactMap(\.prepared).map { BodyImage(fileURL: $0.url, mimeType: $0.mimeType, byteCount: $0.byteCount) }
    let spec = RequestBodySpec(images: images, promptText: trimmedText, settings: effective)
    return (try? RequestBodyWriter.predictedSize(spec)) ?? 0
  }

  /// Contextual status indicator displaying attachment inventory, transmission budget, or blocking conditions.
  var trayCaption: String {
    let counts = trayCounts
    if counts.failed > 0 { return "Remove the image that couldn't be prepared" }
    if counts.pending > 0 { return "Preparing images…" }
    let n = counts.ready
    let mb = String(format: "%.1f MB", Double(projectedBodyBytes) / 1_000_000)
    let budget = String(format: "%.0f MB", Double(BudgetPlanner.budget) / 1_000_000)
    var caption = "\(n) image\(n == 1 ? "" : "s") · \(mb) of \(budget)"
    let limit = capability.highFidelityInputLimit
    if n > limit {
      caption += " · Best results with up to \(limit) images on \(ModelCatalog.descriptor(for: effective.modelID).shortName)"
    }
    return caption
  }

  /// Coordinates asynchronous ingestion and preparation for candidate attachments, logging aggregate results.
  /// Candidates exceeding the tray capacity ceiling are dropped with user notification.
  func attach(_ candidates: [AttachmentCandidate], from source: AttachSource) async {
    guard !candidates.isEmpty else { return }
    let log = services.log
    // Capture snapshot edge setting to guarantee uniform scaling across this batch.
    let edge = services.settings.maxUploadLongEdge
    let room = max(0, Self.maxAttachments - tray.count)
    let kept = Array(candidates.prefix(room))
    let dropped = candidates.count - kept.count
    let action = log.begin(
      "Attach", origin: .user,
      "\(source.rawValue) · \(candidates.count) item\(candidates.count == 1 ? "" : "s") · tray \(tray.count) · max long edge \(edge)")
    let started = ContinuousClock.now
    if dropped > 0 {
      showToast(Self.fullTrayHint)
      log.step(action, "dropped \(dropped) over the 14-image cap")
    }

    // Launch concurrent worker tasks per candidate to parallelize I/O and image transformations.
    var tasks: [(id: UUID, task: Task<TrayItemOutcome, Never>)] = []
    for candidate in kept {
      let id = UUID()
      tray.append(TrayItem(id: id, origin: source.origin, state: .importing, originalFilename: candidate.filename))
      let task = Task { await self.importAndPrepare(id, candidate, parent: action, edge: edge) }
      trayTasks[id] = task
      tasks.append((id, task))
    }
    // Await completion across all child tasks to record the consolidated outcome.
    var outcomes: [TrayItemOutcome] = []
    for (id, task) in tasks {
      outcomes.append(await task.value)
      trayTasks[id] = nil
    }

    let done = outcomes.count(where: { $0 == .prepared })
    let failures = outcomes.compactMap { o -> String? in
      switch o {
      case .importFailed(let r), .prepareFailed(let r): r
      default: nil
      }
    }
    let removed = outcomes.count(where: { $0 == .removed })
    var summary = "in \(Format.seconds(ContinuousClock.now - started)) · "
    if failures.isEmpty {
      summary += "\(done) imported and prepared"
    } else {
      summary += "\(done) of \(kept.count) imported and prepared · \(failures.count) failed: \(failures.joined(separator: "; "))"
    }
    if removed > 0 { summary += " · \(removed) removed" }
    if dropped > 0 { summary += " · \(dropped) dropped over the cap" }
    log.result(action, failures.isEmpty ? .success : .failed, "\(summary)")
  }

  /// Manages the multi-stage ingestion pipeline for a candidate: file staging, metadata inspection, and downsampling.
  /// Re-evaluates presence in the active tray after each suspension point to handle concurrent removals.
  private func importAndPrepare(_ id: UUID, _ candidate: AttachmentCandidate, parent: ActionID, edge: Int) async
    -> TrayItemOutcome
  {
    let dir = services.files.stagingDir
    let staged: URL
    do {
      staged = try await Task.detached { try await candidate.stage(dir, id) }.value
    } catch {
      let reason = Self.importFailure(error)
      services.log.step(parent, "import failed: img \(Format.short(id)): \(reason)")
      let present = update(id, { $0.state = .failed(reason) })
      return present ? .importFailed(reason) : .removed
    }
    // Removed during the staging: no inspection; the staged file goes.
    guard tray.contains(where: { $0.id == id }) else { return Self.discard([staged]) }
    let info: ImageInfo
    do {
      info = try await Task.detached { try ImageInspector.inspect(url: staged) }.value
    } catch {
      let reason = UnsupportedImageError().localizedDescription
      services.log.step(parent, "import failed: img \(Format.short(id)): \(reason)")
      let present = update(
        id,
        { item in
          item.originalURL = staged
          item.state = .failed(reason)
        })
      return present ? .importFailed(reason) : Self.discard([staged])
    }
    let bytes = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    let present = update(
      id,
      { item in
        item.originalURL = staged
        item.originalMimeType = info.mimeType
        item.originalByteCount = bytes
        item.pixelWidth = info.orientedWidth
        item.pixelHeight = info.orientedHeight
      })
    guard present else { return Self.discard([staged]) }
    let described =
      "img \(Format.short(id)) · \(Format.type(info.mimeType)) \(info.pixelWidth)×\(info.pixelHeight) \(Format.mb(bytes)) · orientation \(info.orientation) · alpha \(info.hasAlpha ? "yes" : "no")"
    return await prepare(id, original: staged, parent: parent, edge: edge, described: described)
  }

  /// Executes downsampling and EXIF sanitization for a staged original image.
  /// If the item is cancelled or removed during execution, transient artifacts are deleted.
  private func prepare(_ id: UUID, original: URL, parent: ActionID, edge: Int, described: String) async -> TrayItemOutcome {
    let log = services.log
    guard update(id, { $0.state = .preparing }) else { return Self.discard([original]) }
    let child = log.begin("Prepare attachment", parent: parent, "\(described) · max long edge \(edge)")
    let started = ContinuousClock.now
    let dir = services.files.stagingDir.appendingPathComponent("prepared", isDirectory: true)
    let prepareUpload = services.prepareUpload
    do {
      try FileStore.createDirectory(dir)
      let p = try await prepareUpload(original, edge, dir, id)
      guard update(id, { $0.state = .ready(p) }) else {
        log.result(child, .cancelled, "removed while preparing")
        return Self.discard([original, p.url])
      }
      log.result(
        child, .success,
        "in \(Format.seconds(ContinuousClock.now - started)) · \(Format.type(p.mimeType)) \(p.pixelWidth)×\(p.pixelHeight) \(Format.mb(p.byteCount)) · EXIF stripped"
      )
      return .prepared
    } catch {
      let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      guard update(id, { $0.state = .failed(reason) }) else {
        log.result(child, .cancelled, "removed while preparing")
        return Self.discard([original])
      }
      log.result(child, .failed, "\(reason)")
      return .prepareFailed(reason)
    }
  }

  /// Mutates the targeted tray item in place if it exists in the active collection.
  @discardableResult
  private func update(_ id: UUID, _ change: (inout TrayItem) -> Void) -> Bool {
    guard let i = tray.firstIndex(where: { $0.id == id }) else { return false }
    change(&tray[i])
    return true
  }

  private static func discard(_ urls: [URL]) -> TrayItemOutcome {
    for url in urls { try? FileManager.default.removeItem(at: url) }
    return .removed
  }

  private static func importFailure(_ error: any Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return error.localizedDescription
  }

  /// Shifts the ordering of an attachment item within the composer tray.
  func moveTrayItem(_ id: UUID, by offset: Int) {
    guard let from = tray.firstIndex(where: { $0.id == id }) else { return }
    let to = from + offset
    guard tray.indices.contains(to) else { return }
    let action = services.log.begin(
      "Tray change", origin: .user, "img \(Format.short(id)) · position \(from + 1) → \(to + 1) · tray \(tray.count)")
    tray.swapAt(from, to)
    services.log.result(action, .success, "done")
  }

  /// Removes an attachment item from the tray, cancels pending worker tasks, and deletes staged files.
  func removeTrayItem(_ id: UUID) {
    guard let i = tray.firstIndex(where: { $0.id == id }) else { return }
    let item = tray[i]
    let action = services.log.begin(
      "Tray change", origin: .user, "img \(Format.short(id)) · removed (\(item.stateName)) · tray \(tray.count - 1)")
    tray.remove(at: i)
    trayTasks[id]?.cancel()
    for url in [item.originalURL, item.prepared?.url].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    services.log.result(action, .success, "done")
  }

  /// Clears the composer tray, terminating pending processing tasks and purging staged artifacts.
  private func clearTray() {
    for item in tray {
      trayTasks[item.id]?.cancel()
      for url in [item.originalURL, item.prepared?.url].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
    tray = []
  }

  /// Populates the composer with prior message text, clones upload attachments, restores pinned state,
  /// and prepares images matching current dimension constraints. Prompts for user confirmation if existing draft content exists.
  func editAndResend(userMessageID: UUID, requestID: UUID? = nil, confirmed: Bool = false) async {
    if !confirmed && (!trimmedText.isEmpty || !tray.isEmpty) {
      pendingEdit = (userMessageID, requestID)
      return
    }
    pendingEdit = nil
    let draftAtCheck = (text: trimmedText, items: tray.map(\.id))
    let store = services.store
    guard let info = try? await store.messageInfo(userMessageID), info.role == .user else { return }
    let sources = (try? await store.uploadSources(messageID: userMessageID)) ?? []
    let request = try? await store.requestSnapshot(requestID ?? info.requestID ?? UUID())
    let restore: UUID? =
      if let request, request.selectionReason == .pinned || request.selectionReason == .latest { request.inputs.first?.imageID }
      else { nil }
    let restorable: UUID? = if let restore, (try? await store.imageFile(restore)) != nil { restore } else { nil }
    if (trimmedText, tray.map(\.id)) != draftAtCheck, !trimmedText.isEmpty || !tray.isEmpty {
      pendingEdit = (userMessageID, requestID)
      return
    }
    let edge = services.settings.maxUploadLongEdge
    let log = services.log
    let action = log.begin(
      "Edit and Resend", origin: .user,
      "message \(Format.short(userMessageID)) · text \(info.text.count) characters · attachments to clone \(sources.count) · pin to restore \(restorable.map { "img \(Format.short($0))" } ?? "none")"
    )
    if !tray.isEmpty {
      log.step(action, "replaced the draft: \(tray.count) tray item\(tray.count == 1 ? "" : "s") removed")
      clearTray()
    }
    composerText = info.text
    if let restorable { try? await store.setPin(conversationID, imageID: restorable) }
    isTextFieldFocused = true

    var tasks: [(id: UUID, task: Task<TrayItemOutcome, Never>)] = []
    var failures: [String] = []
    var made = 0
    for source in sources {
      switch cloneIntoTray(source, edge: edge) {
      case .failure(let error):
        failures.append(error.reason)
        log.step(action, "clone failed: img \(Format.short(source.snapshot.imageID)): \(error.reason)")
      case .success(let clone):
        made += 1
        guard let reprepare = clone.reprepare else { continue }
        let described =
          "img \(Format.short(clone.id)) (clone of img \(Format.short(source.snapshot.imageID))) · \(Format.type(source.snapshot.originalMimeType)) \(source.pixelWidth)×\(source.pixelHeight) \(Format.mb(source.byteCount)) · re-prepare: \(reprepare)"
        let task = Task { await self.prepare(clone.id, original: clone.original, parent: action, edge: edge, described: described) }
        trayTasks[clone.id] = task
        tasks.append((clone.id, task))
      }
    }
    var reprepared = 0
    for (id, task) in tasks {
      let outcome = await task.value
      trayTasks[id] = nil
      switch outcome {
      case .prepared: reprepared += 1
      case .prepareFailed(let reason), .importFailed(let reason): failures.append(reason)
      default: break
      }
    }
    var summary = "clones made \(made) · clones re-prepared \(reprepared) · pin \(restorable == nil ? "not restored" : "restored")"
    if !failures.isEmpty { summary += " · \(failures.count) failed: \(failures.joined(separator: "; "))" }
    log.result(action, failures.isEmpty ? .success : .failed, "\(summary)")
    await reload()
  }

  private struct Clone {
    let id: UUID
    let original: URL
    /// Rationale for re-preparation if existing prepared asset cannot be cloned directly.
    let reprepare: String?
  }

  /// Clones persisted original and preprocessed images into staging storage under new identifiers.
  private func cloneIntoTray(_ source: UploadSource, edge: Int) -> Result<Clone, CloneError> {
    let files = services.files
    let snap = source.snapshot
    let id = UUID()
    let ext = URL(fileURLWithPath: snap.originalRelativePath).pathExtension
    let original = files.stagingURL(id, ext: ext.isEmpty ? MimeTypes.fileExtension(for: snap.originalMimeType) : ext)
    do {
      guard files.exists(relative: snap.originalRelativePath) else { throw CloneError("The original image is missing.") }
      try files.cloneItem(at: files.url(relative: snap.originalRelativePath), to: original)
    } catch {
      return .failure((error as? CloneError) ?? CloneError(error.localizedDescription))
    }
    var item = TrayItem(
      id: id, origin: snap.origin, state: .preparing, originalURL: original, originalMimeType: snap.originalMimeType,
      originalByteCount: source.byteCount, pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight,
      originalFilename: source.originalFilename)
    var reprepare: String?
    if let p = snap.prepared, snap.preparedLongEdgeSetting == edge, files.exists(relative: p.preparedRelativePath) {
      let from = files.url(relative: p.preparedRelativePath)
      let to = files.stagingDir.appendingPathComponent("prepared/\(id.uuidString)-\(edge).\(from.pathExtension)")
      do {
        try files.cloneItem(at: from, to: to)
        item.state = .ready(
          PreparedImage(
            url: to, mimeType: p.mimeType, byteCount: p.byteCount, pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight,
            longEdgeSetting: edge))
      } catch {
        reprepare = "prepared file couldn't be cloned"
      }
    } else if snap.prepared == nil || !files.exists(relative: snap.prepared?.preparedRelativePath ?? "") {
      reprepare = "prepared file missing"
    } else {
      reprepare = "edge setting changed from \(snap.preparedLongEdgeSetting ?? 0)"
    }
    tray.append(item)
    return .success(Clone(id: id, original: original, reprepare: reprepare))
  }

  struct CloneError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
  }
}
