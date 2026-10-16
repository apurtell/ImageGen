import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where an Attach came from: the log's source and the stored origin.
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

/// One image on its way into the tray. `stage` writes its original bytes, unchanged, into the
/// staging folder under the item's ID and returns the file (D§4.8 step 1).
struct AttachmentCandidate: Sendable {
  var filename: String?
  var stage: @Sendable (_ stagingDir: URL, _ id: UUID) async throws -> URL

  /// Bytes from the Photos picker or the pasteboard; the type comes from the bytes.
  static func data(_ data: Data, filename: String? = nil, preferredExtension: String? = nil) -> AttachmentCandidate {
    AttachmentCandidate(filename: filename) { dir, id in
      try AttachmentStaging.write(data, into: dir, id: id, preferredExtension: preferredExtension)
    }
  }

  /// A file from the Files importer, copied under its security scope.
  static func file(_ url: URL) -> AttachmentCandidate {
    AttachmentCandidate(filename: url.lastPathComponent) { dir, id in
      try FileImport.copySecurityScoped(url, into: dir, id: id)
    }
  }
}

enum AttachmentStaging {
  /// Writes `data` as `<dir>/<id>.<ext>`, the extension from the image type the bytes declare
  /// (`CGImageSourceGetType`). Bytes that aren't an image are rejected.
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

/// An attachment in the composer tray (D§3.5).
struct TrayItem: Identifiable, Equatable, Sendable {
  enum State: Equatable, Sendable {
    case importing
    case preparing
    case ready(PreparedImage)
    case failed(String)
  }

  let id: UUID
  let origin: ImageOrigin
  var state: State
  var originalURL: URL?
  var originalMimeType = ""
  var originalByteCount = 0
  /// As displayed (orientation applied).
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

  /// What the send records (D§4.3).
  var staged: StagedAttachment? {
    guard let prepared, let originalURL else { return nil }
    return StagedAttachment(
      id: id, origin: origin, originalURL: originalURL, originalMimeType: originalMimeType,
      originalByteCount: originalByteCount, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      originalFilename: originalFilename, prepared: prepared)
  }
}

/// How one tray item's import and preparation ended, for its parent's Result.
enum TrayItemOutcome: Sendable, Equatable {
  case prepared
  case reused
  case importFailed(String)
  case prepareFailed(String)
  case removed
}

/// Attachments (D§3.5, D§4.8) and Edit & Resend (D§3.6): the tray, its imports and preparation,
/// the budget caption, and cloning a sent message's uploads.
extension ChatScreenModel {
  static let maxAttachments = 14
  static let fullTrayHint = "Up to 14 images per message"

  var trayCounts: TrayCounts {
    TrayCounts(
      ready: tray.count(where: { $0.prepared != nil }), pending: tray.count(where: \.isPending),
      failed: tray.count(where: { $0.failure != nil }))
  }

  var canAddAttachments: Bool { tray.count < Self.maxAttachments }

  /// The Photos picker's limit. Never 0, which the picker treats as "no limit".
  static func pickerLimit(trayCount: Int) -> Int { max(1, maxAttachments - trayCount) }
  var pickerLimit: Int { Self.pickerLimit(trayCount: tray.count) }

  /// The body the ready items would make with the current text and settings (`predictedSize`).
  var projectedBodyBytes: Int {
    let images = tray.compactMap(\.prepared).map { BodyImage(fileURL: $0.url, mimeType: $0.mimeType, byteCount: $0.byteCount) }
    let spec = RequestBodySpec(images: images, promptText: trimmedText, settings: effective)
    return (try? RequestBodyWriter.predictedSize(spec)) ?? 0
  }

  /// "3 images · 6.1 MB of 19 MB", or why Send is blocked (D§3.5).
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

  // MARK: Attach

  /// Imports and prepares the candidates, logged as one Attach action whose Result follows every
  /// Prepare attachment it started (plan §2.8). Extras over the 14-image cap are dropped with a toast.
  func attach(_ candidates: [AttachmentCandidate], from source: AttachSource) async {
    guard !candidates.isEmpty else { return }
    let log = services.log
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

    var tasks: [(id: UUID, task: Task<TrayItemOutcome, Never>)] = []
    for candidate in kept {
      let id = UUID()
      tray.append(TrayItem(id: id, origin: source.origin, state: .importing, originalFilename: candidate.filename))
      let task = Task { await self.importAndPrepare(id, candidate, parent: action, edge: edge) }
      trayTasks[id] = task
      tasks.append((id, task))
    }
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

  /// Stages one candidate's original, then prepares it. A failed import begins no Prepare attachment.
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

  /// Prepares a staged original as a Prepare attachment sub-action (D§4.8 step 3). An item removed
  /// meanwhile ends it `cancelled`, and its files are deleted.
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

  /// Applies `change` to the item if it's still in the tray; returns whether it was.
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

  // MARK: Tray changes

  /// Moves an item one place left (-1) or right (+1); logged as a Tray change.
  func moveTrayItem(_ id: UUID, by offset: Int) {
    guard let from = tray.firstIndex(where: { $0.id == id }) else { return }
    let to = from + offset
    guard tray.indices.contains(to) else { return }
    let action = services.log.begin(
      "Tray change", origin: .user, "img \(Format.short(id)) · position \(from + 1) → \(to + 1) · tray \(tray.count)")
    tray.swapAt(from, to)
    services.log.result(action, .success, "done")
  }

  /// Removes an item and deletes its staged files; a preparing item's Prepare attachment ends `cancelled`.
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

  /// Empties the tray, deleting its staged files (Edit & Resend replacing the draft).
  private func clearTray() {
    for item in tray {
      trayTasks[item.id]?.cancel()
      for url in [item.originalURL, item.prepared?.url].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
    tray = []
  }

  // MARK: Edit & Resend

  /// Edit & Resend (D§3.6): loads the message text into the composer, clones its uploads into the
  /// tray (re-preparing a clone made at another max long edge or missing its prepared file),
  /// restores the pin when the request used `.pinned` or `.latest`, and focuses the text field.
  /// A non-empty draft (text or tray) asks first. The Result follows every re-prepare.
  func editAndResend(userMessageID: UUID, requestID: UUID? = nil, confirmed: Bool = false) async {
    if !confirmed && (!trimmedText.isEmpty || !tray.isEmpty) {
      pendingEdit = (userMessageID, requestID)
      return
    }
    pendingEdit = nil
    let store = services.store
    guard let info = try? await store.messageInfo(userMessageID), info.role == .user else { return }
    let sources = (try? await store.uploadSources(messageID: userMessageID)) ?? []
    let request = try? await store.requestSnapshot(requestID ?? info.requestID ?? UUID())
    let restore: UUID? =
      if let request, request.selectionReason == .pinned || request.selectionReason == .latest { request.inputs.first?.imageID }
      else { nil }
    let restorable: UUID? = if let restore, (try? await store.imageFile(restore)) != nil { restore } else { nil }
    let edge = services.settings.maxUploadLongEdge
    let log = services.log
    let action = log.begin(
      "Edit & Resend", origin: .user,
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
    /// Why it must be re-prepared, or nil when its prepared file was cloned as is.
    let reprepare: String?
  }

  /// Clones an upload's original (and its prepared file, when it was made at the current max long
  /// edge) into `Staging/` with a new ID, and adds the tray item.
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
