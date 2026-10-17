import Foundation

/// Why a body couldn't be prepared. Each case maps to a `LocalErrorStatus` for the record, and to
/// the message that the reply card and the log show.
enum PrepareError: Error, Equatable {
  /// The body is over the budget even when no image can shrink further; `mb` is that predicted size.
  case tooLarge(mb: Double)
  /// An input's original is gone (a missing prepared file is re-made instead).
  case inputMissing
  case diskFull
  case noAPIKey
  /// The body would have no text and no image.
  case emptyParts

  var status: LocalErrorStatus {
    switch self {
    case .tooLarge: .tooLarge
    case .inputMissing: .inputMissing
    case .diskFull: .diskFull
    case .noAPIKey: .noAPIKey
    case .emptyParts: .emptyParts
    }
  }

  var message: String {
    switch self {
    case .tooLarge(let mb):
      "Images too large to send together (\(String(format: "%.1f", mb)) MB). Remove some or lower the max size in Settings."
    case .inputMissing: "An input image was deleted."
    case .diskFull: "Not enough storage to write the request."
    case .noAPIKey: "No API key"
    case .emptyParts: "Could not extract any content from the conversation."
    }
  }
}

/// The result of a preparation: where `body.json` is, its size, and the inputs it contains.
struct PreparedBody: Sendable, Equatable {
  let url: URL
  let size: Int
  let inputs: [RequestInput]
}

/// Turns a recorded request into `body.json` (D§4.8 steps 4–5): resolves each input to the bytes
/// to send, re-prepares a reused upload when its prepared file is missing or was made at another
/// max long edge, fits the body under the budget, and streams it to disk. Logs a Prepare request
/// sub-action under the request's action.
///
/// Place in the design: only `GenerationService` calls it, for a first send, a Regenerate, a Retry
/// that must rebuild its body, and a CIVIC rebuild. It calls `ImagePreprocessor`, `BudgetPlanner`
/// and `RequestBodyWriter`, and `DataStore` to record the files it used.
///
/// Concurrency model: a `Sendable` struct with no state of its own. Its slow steps (decode, shrink,
/// body write) are `@concurrent` functions that run off the caller's actor, so the service actor
/// serves other calls meanwhile. Cancellation is cooperative: the caller cancels the preparation's
/// task (a Stop, or the end of background time), and this code checks between steps, then removes
/// any half-written body (D§5). See the primer, *Tasks and cancellation*.
struct RequestPreparer: Sendable {
  let files: FileStore
  let store: DataStore
  let log: ActivityLog
  let defaults: @Sendable () -> GenerationDefaults
  var shrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor
  var budget = BudgetPlanner.budget

  /// Where the bytes for one input come from. Each case carries the data it needs (an enum with
  /// associated values).
  private enum Source {
    /// The file recorded on the request: what an earlier send of it used.
    case recorded(RequestInput)
    /// The upload's current prepared file, made at the current max long edge.
    case prepared(RequestInput)
    /// The original file, sent as it is (a model output; never re-encoded).
    case original(InputSnapshot)
    /// An upload whose prepared file must be made again from its original.
    case reprepare(InputSnapshot, reason: String)
  }

  /// `reuseRecorded`: Regenerate and Retry send the recorded inputs verbatim while their files
  /// exist; a first send checks reused uploads against the current max long edge.
  func prepare(
    _ snap: RequestSnapshot, parent: ActionID, reuseRecorded: Bool, categories: [HarmCategory]? = nil
  ) async throws -> PreparedBody {
    let edge = defaults().maxUploadLongEdge
    let assets = Dictionary(snap.inputAssets.map { ($0.imageID, $0) }, uniquingKeysWith: { a, _ in a })

    // Decide first, so the Begin states every decision.
    var sources: [Source] = []
    var notes: [String] = []
    var missing = false
    for input in snap.inputs {
      let img = "img \(Format.short(input.imageID))"
      let asset = assets[input.imageID]
      let recordedExists = files.exists(relative: input.preparedRelativePath)
      if asset?.origin == .model {
        if reuseRecorded && recordedExists {
          sources.append(.recorded(input))
          notes.append("\(img): recorded file")
        } else if let a = asset, files.exists(relative: a.originalRelativePath) {
          sources.append(.original(a))
          notes.append("\(img): original bytes (model output)")
        } else {
          missing = true
          notes.append("\(img): original missing")
        }
        continue
      }
      if recordedExists && (reuseRecorded || snap.selectionReason == .attachments) {
        sources.append(.recorded(input))
        notes.append("\(img): \(reuseRecorded ? "recorded file" : "prepared at send")")
      } else if let a = asset, let p = a.prepared, files.exists(relative: p.preparedRelativePath),
        a.preparedLongEdgeSetting == edge
      {
        sources.append(.prepared(p))
        notes.append("\(img): reuse prepared file (made at \(edge))")
      } else if let a = asset, files.exists(relative: a.originalRelativePath) {
        let reason =
          a.prepared.map { files.exists(relative: $0.preparedRelativePath) } == true
          ? "edge setting changed from \(a.preparedLongEdgeSetting ?? 0)" : "prepared file missing"
        sources.append(.reprepare(a, reason: reason))
        notes.append("\(img): re-prepare at \(edge) (\(reason))")
      } else if recordedExists {
        sources.append(.recorded(input))
        notes.append("\(img): recorded file")
      } else {
        missing = true
        notes.append("\(img): original missing")
      }
    }

    let started = ContinuousClock.now
    let action = log.begin(
      "Prepare request", parent: parent,
      "\(snap.inputs.count) input\(snap.inputs.count == 1 ? "" : "s") · budget \(String(format: "%.1f", Double(budget) / 1_000_000)) MB · max long edge \(edge)\(notes.isEmpty ? "" : " · " + notes.joined(separator: " · "))"
    )
    // Exactly one Result for the Prepare request sub-action, on every path: `defer` runs when the
    // function exits, and each path sets `outcome` and `summary` first.
    var outcome = ActivityOutcome.failed
    var summary: ActivityMessage = "unknown error"
    defer { log.result(action, outcome, summary) }

    do {
      if missing { throw PrepareError.inputMissing }

      // Resolve to files.
      var images: [PreparedImage] = []
      var ids: [UUID] = []
      for source in sources {
        try Task.checkCancellation()
        switch source {
        case .recorded(let input), .prepared(let input):
          images.append(preparedImage(input, edge: edge))
          ids.append(input.imageID)
        case .original(let a):
          let url = files.url(relative: a.originalRelativePath)
          let info = try ImageInspector.inspect(url: url)
          let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          images.append(
            PreparedImage(
              url: url, mimeType: a.originalMimeType, byteCount: bytes, pixelWidth: info.orientedWidth,
              pixelHeight: info.orientedHeight, longEdgeSetting: edge))
          ids.append(a.imageID)
        case .reprepare(let a, _):
          let prepared = try await ImagePreprocessor.prepare(
            source: files.url(relative: a.originalRelativePath), maxLongEdge: edge,
            destinationDir: files.conversationDir(snap.conversationID).appendingPathComponent("prepared"), id: a.imageID)
          // Record the new file on the image, so a later send reuses it.
          let input = requestInput(prepared, id: a.imageID)
          try await store.setPreparedFile(imageID: a.imageID, input, longEdgeSetting: edge)
          images.append(prepared)
          ids.append(a.imageID)
        }
      }

      // Budget. `categories` replaces the recorded ones for a CIVIC rebuild. The envelope is the
      // body without its image bytes; `BudgetPlanner` shrinks images until the total fits.
      var settings = snap.settings
      if let categories { settings.categories = categories }
      let envelope = try RequestBodyWriter.predictedSize(
        RequestBodySpec(
          images: images.map { BodyImage(fileURL: $0.url, mimeType: $0.mimeType, byteCount: 0) },
          promptText: snap.promptText, settings: settings))
      let preparedDir = files.conversationDir(snap.conversationID).appendingPathComponent("prepared")
      // A local copy, so the closure below captures this one function and not the whole preparer.
      let shrink = self.shrink
      let fitted: BudgetPlanner.Fitted
      do {
        fitted = try await BudgetPlanner.fit(images, envelopeBytes: envelope, budget: budget) { image, target in
          var out = try await shrink(image, target)
          // A shrunk model output goes into prepared/ with the uploads' API-ready files (D§4.4).
          if out.url.deletingLastPathComponent().standardizedFileURL != preparedDir.standardizedFileURL {
            let dest = preparedDir.appendingPathComponent(out.url.lastPathComponent)
            try FileStore.createDirectory(preparedDir)
            // Best effort: a stale file left here makes the move below throw, and that is reported.
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: out.url, to: dest)
            out = PreparedImage(
              url: dest, mimeType: out.mimeType, byteCount: out.byteCount, pixelWidth: out.pixelWidth,
              pixelHeight: out.pixelHeight, longEdgeSetting: out.longEdgeSetting)
          }
          return out
        }
      } catch let error as BudgetTooLarge {
        throw PrepareError.tooLarge(mb: Double(error.bodyBytes) / 1_000_000)
      }

      // Body.
      try Task.checkCancellation()
      let bodyURL = files.bodyURL(snap.id)
      // A body from an earlier attempt; the write below replaces it anyway.
      try? FileManager.default.removeItem(at: bodyURL)
      let spec = RequestBodySpec(
        images: fitted.images.map { BodyImage(fileURL: $0.url, mimeType: $0.mimeType, byteCount: $0.byteCount) },
        promptText: snap.promptText, settings: settings)
      let size: Int
      do {
        size = try await RequestBodyWriter.write(spec, to: bodyURL)
      } catch RequestBodyError.emptyParts {
        throw PrepareError.emptyParts
      } catch {
        // Cleanup after a failed write; the Janitor removes anything left (D§4.4).
        try? FileManager.default.removeItem(at: bodyURL)
        if Self.isDiskFull(error) { throw PrepareError.diskFull }
        throw error
      }
      // The write may finish even though a cancel arrived during it; a cancelled preparation must
      // not leave a body that looks ready.
      if Task.isCancelled {
        // Cleanup on cancellation; the Janitor removes anything left (D§4.4).
        try? FileManager.default.removeItem(at: bodyURL)
        throw CancellationError()
      }

      // Record the bytes actually sent (after any shrink), so Regenerate and Retry send the same ones.
      let inputs = zip(ids, fitted.images).map { requestInput($1, id: $0) }
      try await store.updateRequest(snap.id) { patch in
        patch.inputs = inputs
        if let categories { patch.categories = categories }
      }

      let shrinks =
        fitted.shrinks.isEmpty
        ? "no shrink"
        : fitted.shrinks.map { "shrink img \(Format.short(ids[$0.index])) \($0.fromLongEdge) → \($0.toLongEdge)" }
          .joined(separator: " · ")
      outcome = .success
      summary = "in \(Format.seconds(ContinuousClock.now - started)) · body.json \(Format.mb(size)) · \(shrinks)"
      return PreparedBody(url: bodyURL, size: size, inputs: inputs)
    } catch let error as PrepareError {
      summary = "\(error.message)"
      throw error
    } catch is CancellationError {
      outcome = .interrupted
      summary = "preparation cancelled"
      // Cleanup on cancellation; the Janitor removes anything left (D§4.4).
      try? FileManager.default.removeItem(at: files.bodyURL(snap.id))
      throw CancellationError()
    } catch {
      if Self.isDiskFull(error) {
        summary = "\(PrepareError.diskFull.message)"
        throw PrepareError.diskFull
      }
      summary = "\(error.localizedDescription)"
      throw error
    }
  }

  private func preparedImage(_ input: RequestInput, edge: Int) -> PreparedImage {
    PreparedImage(
      url: files.url(relative: input.preparedRelativePath), mimeType: input.mimeType, byteCount: input.byteCount,
      pixelWidth: input.pixelWidth, pixelHeight: input.pixelHeight, longEdgeSetting: edge)
  }

  private func requestInput(_ p: PreparedImage, id: UUID) -> RequestInput {
    RequestInput(
      imageID: id, preparedRelativePath: files.relativePath(of: p.url) ?? p.url.path, mimeType: p.mimeType,
      byteCount: p.byteCount, pixelWidth: p.pixelWidth, pixelHeight: p.pixelHeight)
  }

  /// True for an out-of-space error, also when it is wrapped as the underlying error of another one.
  static func isDiskFull(_ error: any Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
    return false
  }
}
