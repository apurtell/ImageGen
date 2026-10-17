import Foundation

/// Errors encountered during generation request payload construction.
enum PrepareError: Error, Equatable {
  /// Aggregate payload exceeds maximum upload budget after exhausting all downsizing iterations.
  case tooLarge(mb: Double)
  /// Referenced input image is absent from persistent storage.
  case inputMissing
  case diskFull
  case noAPIKey
  /// Request payload lacks both textual prompts and multimodal image parts.
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

/// Output artifacts resulting from successful generation request payload preparation.
struct PreparedBody: Sendable, Equatable {
  let url: URL
  let size: Int
  let inputs: [RequestInput]
}

/// Orchestrates request serialization and payload budget fitting. Resolves input assets from persistent storage,
/// rescales images according to resolution preferences and total payload constraints, and streams JSON directly to disk.
/// Diagnostic telemetry for preparation is nested under the parent generation action.
struct RequestPreparer: Sendable {
  let files: FileStore
  let store: DataStore
  let log: ActivityLog
  let defaults: @Sendable () -> GenerationDefaults
  var shrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor
  var budget = BudgetPlanner.budget

  /// Origin strategy for sourcing serialized input image data.
  private enum Source {
    /// Staged file previously recorded on the request record.
    case recorded(RequestInput)
    /// Existing prepared representation matching the current resolution configuration.
    case prepared(RequestInput)
    /// Original uncompressed image data (e.g. prior model output transferred verbatim).
    case original(InputSnapshot)
    /// Upload asset requiring re-scaling from source due to resolution settings changes.
    case reprepare(InputSnapshot, reason: String)
  }

  /// Prepares and serializes the JSON request payload for transmission to the Gemini API.
  func prepare(
    _ snap: RequestSnapshot, parent: ActionID, reuseRecorded: Bool, categories: [HarmCategory]? = nil
  ) async throws -> PreparedBody {
    let edge = defaults().maxUploadLongEdge
    let assets = Dictionary(snap.inputAssets.map { ($0.imageID, $0) }, uniquingKeysWith: { a, _ in a })

    // Resolve source strategies for all inputs to inform diagnostic logging.
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
    // Conclude preparation sub-activity on all exit paths.
    var outcome = ActivityOutcome.failed
    var summary: ActivityMessage = "unknown error"
    defer { log.result(action, outcome, summary) }

    do {
      if missing { throw PrepareError.inputMissing }

      // Resolve and scale image files.
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
          // Update persistent image record with generated representations to optimize future reuse.
          let input = requestInput(prepared, id: a.imageID)
          try await store.setPreparedFile(imageID: a.imageID, input, longEdgeSetting: edge)
          images.append(prepared)
          ids.append(a.imageID)
        }
      }

      // Budget fitting: estimate non-image payload envelope and iteratively downscale images to fit overall budget.
      var settings = snap.settings
      if let categories { settings.categories = categories }
      let envelope = try RequestBodyWriter.predictedSize(
        RequestBodySpec(
          images: images.map { BodyImage(fileURL: $0.url, mimeType: $0.mimeType, byteCount: 0) },
          promptText: snap.promptText, settings: settings))
      let preparedDir = files.conversationDir(snap.conversationID).appendingPathComponent("prepared")
      let shrink = self.shrink
      let fitted: BudgetPlanner.Fitted
      do {
        fitted = try await BudgetPlanner.fit(images, envelopeBytes: envelope, budget: budget) { image, target in
          var out = try await shrink(image, target)
          // Relocate downscaled model outputs to prepared image storage.
          if out.url.deletingLastPathComponent().standardizedFileURL != preparedDir.standardizedFileURL {
            let dest = preparedDir.appendingPathComponent(out.url.lastPathComponent)
            try FileStore.createDirectory(preparedDir)
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

      // Payload generation.
      try Task.checkCancellation()
      let bodyURL = files.bodyURL(snap.id)
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
        try? FileManager.default.removeItem(at: bodyURL)
        if Self.isDiskFull(error) { throw PrepareError.diskFull }
        throw error
      }
      if Task.isCancelled {
        try? FileManager.default.removeItem(at: bodyURL)
        throw CancellationError()
      }

      // Commit serialized input references to the request record to ensure deterministic re-execution.
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

  /// Identifies out-of-space filesystem conditions across direct errors and nested causes.
  static func isDiskFull(_ error: any Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
    return false
  }
}
