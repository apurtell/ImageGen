import Foundation

/// The UI's only way into generation (M5's `ChatScreenModel` depends on this protocol alone).
protocol GenerationServicing: Sendable {
  func send(_ d: SendDraft) async throws -> UUID
  func regenerate(sourceRequestID: UUID) async throws -> UUID
  func retry(requestID: UUID) async throws
  func cancel(requestID: UUID) async
}

enum GenerationError: Error, Equatable {
  /// One request in flight per chat (D§4.6).
  case chatBusy
  case requestNotFound
  case notRetryable(RequestState)
  case inputMissing
  /// Preparation failed; the request record holds the details.
  case preparationFailed(LocalErrorStatus)
  /// The background-task assertion expired before the task started.
  case interrupted
  case cancelled
}

/// The single owner of request state transitions (D§4.6, D§6). It consumes the transport's
/// ordered event stream in one task, handling each event to the end before taking the next, and
/// logs each request as one action (Send, Regenerate or Retry) with Prepare request, Attempt and
/// Parse sub-actions (D§4.13).
actor GenerationService: GenerationServicing {
  struct Dependencies: Sendable {
    var transport: any GenerationTransport
    var store: DataStore
    var files: FileStore
    var keyStore: any APIKeyStore
    var log: ActivityLog
    var backgroundTasks: any BackgroundTaskProviding
    var notifier: any NotificationPosting
    var activity: AppActivity
    var thumbnails: ThumbnailService?
    var retryPolicy = RetryPolicy()
    /// The current Settings defaults, read without the main actor.
    var defaults: @Sendable () -> GenerationDefaults
    /// Sets `AppSettings.omitCivicIntegrity` on the main actor (the actor never writes defaults).
    var setOmitCivicOnMain: @Sendable () async -> Void
    var onBackgroundEventsFinished: @Sendable (_ sessionID: String, _ completionsHandled: Int) async -> Void
    /// For the Attempt Begin: "background session" or "ephemeral session".
    var sessionDescription = "background session"
    var shrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor
    var budget = BudgetPlanner.budget
    var clock: @Sendable () -> Date = { Date() }
  }

  /// A cancellable preparation, and whether the background-task assertion expired during it.
  private final class Preparation: Sendable {
    let expired = Locked(false)
    let task = Locked<Task<Void, any Error>?>(nil)

    func cancel() { task.value?.cancel() }
  }

  private final class ConsumerBox: Sendable {
    let task = Locked<Task<Void, Never>?>(nil)
  }

  private let d: Dependencies
  private let preparer: RequestPreparer
  private let consumer = ConsumerBox()

  /// Chats with a send between the tap and the request record's creation.
  private var busyConversations: Set<UUID> = []
  private var conversationOf: [UUID: UUID] = [:]
  /// requestID → the action following it in this process (begun here or adopted).
  private var actions: [UUID: ActionID] = [:]
  /// requestID → a Late completion action.
  private var lateActions: [UUID: ActionID] = [:]
  /// requestID → its open Attempt sub-action.
  private var attemptActions: [UUID: ActionID] = [:]
  private var startedAt: [UUID: ContinuousClock.Instant] = [:]
  private var userCancelled: Set<UUID> = []
  private var replacedTasks: Set<Int> = []
  private var preparations: [UUID: Preparation] = [:]
  private var completionsSinceFinished = 0

  init(_ dependencies: Dependencies) {
    d = dependencies
    preparer = RequestPreparer(
      files: dependencies.files, store: dependencies.store, log: dependencies.log, defaults: dependencies.defaults,
      shrink: dependencies.shrink, budget: dependencies.budget)
    let events = dependencies.transport.events
    consumer.task.withLock {
      $0 = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          await self.handle(event)
        }
      }
    }
  }

  /// Stops consuming events (tests that simulate a relaunch).
  nonisolated func stop() {
    consumer.task.value?.cancel()
  }

  // MARK: Send, Regenerate, Retry, Cancel

  func send(_ draft: SendDraft) async throws -> UUID {
    let conv = draft.conversationID
    try await claim(conv)
    var claimed = true
    defer { if claimed { busyConversations.remove(conv) } }

    let history = try await d.store.selectorHistory(conv: conv)
    let pin = try await d.store.pinState(conv: conv)
    let selection = InputSelector.select(
      SelectionInput(
        attachments: draft.attachments.map(\.id), pinnedImageID: pin.id, pinnedImageExists: pin.exists, history: history))
    let reused = selection.reason == .attachments ? [] : try await d.store.inputSnapshots(selection.imageIDs)
    let inputs = describeInputs(selection, attachments: draft.attachments, reused: reused)
    let action = d.log.begin(
      "Send", origin: .user,
      "\(describe(draft.settings)) · input \(inputs) · chat \(Format.short(conv)) · prompt \(private: Self.quoted(draft.promptText))"
    )
    // The ID goes into the request record only once its Begin is in the file (plan §2.8 rule 9).
    await d.log.flush(timeout: .seconds(1))
    let started = ContinuousClock.now

    let input = SendRecordInput(
      conversationID: conv, promptText: draft.promptText, attachments: draft.attachments, selection: selection,
      settings: draft.settings, activityActionID: action)
    let requestID = try await prepareWithAssertion(
      action: action, conversation: conv, started: started, reuseRecorded: false
    ) {
      let record = try await self.d.store.createSend(input)
      return record.requestID
    }
    claimed = false
    return requestID
  }

  func regenerate(sourceRequestID: UUID) async throws -> UUID {
    guard let source = try await d.store.requestSnapshot(sourceRequestID) else { throw GenerationError.requestNotFound }
    let conv = source.conversationID
    try await claim(conv)
    var claimed = true
    defer { if claimed { busyConversations.remove(conv) } }

    let action = d.log.begin(
      "Regenerate", origin: .user,
      "source req \(Format.short(sourceRequestID)) · recorded values reused · \(describe(source.settings)) · input \(describeRecorded(source)) · chat \(Format.short(conv)) · prompt \(private: Self.quoted(source.promptText))"
    )
    await d.log.flush(timeout: .seconds(1))
    let started = ContinuousClock.now
    let omitCivic = d.defaults().omitCivicIntegrity && source.settings.categories.contains(.civicIntegrity)
    let requestID = try await prepareWithAssertion(
      action: action, conversation: conv, started: started, reuseRecorded: true,
      categories: omitCivic ? source.settings.categories.filter { $0 != .civicIntegrity } : nil
    ) {
      guard let record = try await self.d.store.createRegenerate(sourceRequestID: sourceRequestID, activityActionID: action)
      else { throw PrepareError.inputMissing }
      if omitCivic { self.d.log.step(action, "CIVIC_INTEGRITY omitted since the original: 4 categories") }
      return record.requestID
    }
    claimed = false
    return requestID
  }

  func retry(requestID: UUID) async throws {
    guard let snap = try await d.store.requestSnapshot(requestID) else { throw GenerationError.requestNotFound }
    guard [.failed, .refused, .cancelled, .interrupted].contains(snap.state) else {
      throw GenerationError.notRetryable(snap.state)
    }
    let conv = snap.conversationID
    try await claim(conv)
    var claimed = true
    defer { if claimed { busyConversations.remove(conv) } }

    let action = d.log.begin(
      "Retry", origin: .user,
      "req \(Format.short(requestID)) · attempt \(snap.attempt + 1) · auto-retry budget reset · \(describe(snap.settings)) · input \(describeRecorded(snap)) · prompt \(private: Self.quoted(snap.promptText))"
    )
    await d.log.flush(timeout: .seconds(1))
    let started = ContinuousClock.now
    _ = try await prepareWithAssertion(
      action: action, conversation: conv, started: started, reuseRecorded: true,
      rebuildBody: !FileManager.default.fileExists(atPath: d.files.bodyURL(requestID).path)
    ) {
      try await self.d.store.updateRequest(requestID) { p in
        p.clearOutcome = true
        p.state = .preparing
        p.autoRetriesUsed = 0
        p.nextAttemptAt = .some(nil)
        p.taskIdentifier = .some(nil)
        p.nextAttemptCreatedInBackground = false
        p.activityActionID = action
      }
      return requestID
    }
    claimed = false
  }

  func cancel(requestID: UUID) async {
    guard let snap = try? await d.store.requestSnapshot(requestID), snap.state.isLive else { return }
    let action = d.log.begin("Cancel", origin: .user, "req \(Format.short(requestID)) · state \(snap.state.rawValue)")
    userCancelled.insert(requestID)
    if let prep = preparations[requestID] {
      prep.cancel()
      d.log.result(action, .success, "preparation cancelled")
      return
    }
    await d.transport.cancel(requestID: requestID)
    d.log.result(action, .success, "task cancelled")
  }

  /// Re-creates in the foreground every retry task created while the app was inactive, which the
  /// system may treat as discretionary (D§6).
  func appBecameActive() async {
    guard let pending = try? await d.store.nonTerminalRequests() else { return }
    for snap in pending where snap.state == .retryScheduled && snap.nextAttemptCreatedInBackground {
      guard let old = snap.taskIdentifier, let key = try? d.keyStore.read(), !key.isEmpty else { continue }
      let action = actionFor(snap)
      replacedTasks.insert(old)
      await d.transport.cancel(taskIdentifier: old)
      closeAttempt(snap, action: action, outcome: .cancelled, "replaced: re-created in the foreground")
      d.log.step(action, "background-created retry re-created in the foreground")
      let begin = max(d.clock(), snap.nextAttemptAt ?? d.clock())
      do {
        try await startAttempt(
          snap, action: action, attempt: snap.attempt, bodyURL: d.files.bodyURL(snap.id),
          bodySize: Self.fileSize(d.files.bodyURL(snap.id)), earliestBegin: begin, apiKey: key, createdInBackground: false)
      } catch {
        await finishFailed(snap.id, status: .network, message: "couldn't re-create the retry: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Reconciler hooks (D§4.7)

  /// Marks a request interrupted (if it's still live) and closes its action; returns that action.
  @discardableResult
  func markInterrupted(_ requestID: UUID, reason: String) async -> ActionID? {
    guard let snap = try? await d.store.requestSnapshot(requestID), snap.state.isLive else { return nil }
    try? await d.store.updateRequest(requestID) { p in
      p.state = .interrupted
      p.completedAt = self.d.clock()
    }
    let action = actionFor(snap)
    closeAttempt(snap, action: action, outcome: .interrupted, "\(reason)")
    d.log.result(action, .interrupted, "\(reason)")
    forget(requestID, conversation: snap.conversationID)
    return action
  }

  /// Refreshes a request's live task; a delayed task that has begun moves to `inFlight`.
  func refreshLiveTask(_ requestID: UUID, taskIdentifier: Int, began: Bool) async {
    try? await d.store.updateRequest(requestID) { p in
      p.taskIdentifier = .some(taskIdentifier)
    }
    if began, let snap = try? await d.store.requestSnapshot(requestID), snap.state == .retryScheduled {
      try? await d.store.updateRequest(requestID) { $0.state = .inFlight }
    }
  }

  /// Re-parses a response whose `.complete` marker survived a crash (D§4.7 step 4).
  func reparse(_ requestID: UUID) async {
    guard let snap = try? await d.store.requestSnapshot(requestID) else { return }
    let part = d.files.partURL(requestID, attempt: snap.attempt)
    let completion = TransportCompletion(
      requestID: requestID, attempt: snap.attempt, taskIdentifier: -1,
      httpStatus: ResponseAccumulator.markerStatus(d.files.completeMarkerURL(requestID, attempt: snap.attempt)) ?? 200,
      headers: [:], partURL: part, bytesReceived: Self.fileSize(part), error: nil, cancelReason: nil, elapsed: .zero)
    await handleCompleted(completion, reparse: true)
  }

  // MARK: Preparation

  /// Takes the background-task assertion, records the request (`create`), prepares the body and
  /// starts the first attempt, then ends the assertion (D§4.6).
  private func prepareWithAssertion(
    action: ActionID, conversation: UUID, started: ContinuousClock.Instant, reuseRecorded: Bool, rebuildBody: Bool = true,
    categories: [HarmCategory]? = nil, create: @escaping @Sendable () async throws -> UUID
  ) async throws -> UUID {
    let prep = Preparation()
    let log = d.log
    let token = await d.backgroundTasks.begin(name: "gen-prepare") {
      prep.expired.withLock { $0 = true }
      prep.cancel()
      log.result(action, .interrupted, "background time ran out before the request was sent")
    }

    let recorded = Locked<UUID?>(nil)
    let work = Task<Void, any Error> {
      let id = try await create()
      recorded.withLock { $0 = id }
      self.register(id, action: action, conversation: conversation, started: started, preparation: prep)
      try Task.checkCancellation()
      try await self.prepareAndStart(
        id, action: action, reuseRecorded: reuseRecorded, rebuildBody: rebuildBody, categories: categories)
    }
    prep.task.withLock { $0 = work }
    if prep.expired.value { work.cancel() }
    let result = await work.result
    let requestID = recorded.value
    if let id = requestID { preparations[id] = nil }
    await d.backgroundTasks.end(token)

    switch result {
    case .success:
      return requestID!
    case .failure(let error):
      guard let id = requestID else {
        // Nothing was recorded (createSend failed, or a regenerate input is missing).
        if !prep.expired.value {
          d.log.result(action, .failed, "\(Self.describeError(error))")
        }
        busyConversations.remove(conversation)
        throw (error as? PrepareError) == .inputMissing ? GenerationError.inputMissing : error
      }
      if prep.expired.value {
        // The expiry handler already logged the result.
        try? FileManager.default.removeItem(at: d.files.bodyURL(id))
        try? await d.store.updateRequest(id) { p in
          p.state = .interrupted
          p.completedAt = self.d.clock()
        }
        forget(id, conversation: conversation)
        throw GenerationError.interrupted
      }
      if error is CancellationError || userCancelled.contains(id) {
        userCancelled.remove(id)
        try? FileManager.default.removeItem(at: d.files.bodyURL(id))
        try? await d.store.updateRequest(id) { p in
          p.state = .cancelled
          p.completedAt = self.d.clock()
        }
        await finish(id, outcome: .cancelled, summary: "cancelled before sending", notify: false)
        throw GenerationError.cancelled
      }
      let prepError = error as? PrepareError
      let status = prepError?.status ?? .network
      await finishFailed(id, status: status, message: prepError?.message ?? Self.describeError(error))
      throw GenerationError.preparationFailed(status)
    }
  }

  private func register(
    _ id: UUID, action: ActionID, conversation: UUID, started: ContinuousClock.Instant, preparation: Preparation
  ) {
    actions[id] = action
    conversationOf[id] = conversation
    startedAt[id] = started
    preparations[id] = preparation
    // From here the request record (live until terminal) keeps the chat to one request; releasing
    // the in-memory claim now means the chat is free the moment the record turns terminal.
    busyConversations.remove(conversation)
  }

  /// Writes the body (unless an existing one is reused) and starts the next attempt.
  private func prepareAndStart(
    _ id: UUID, action: ActionID, reuseRecorded: Bool, rebuildBody: Bool, categories: [HarmCategory]?,
    earliestBegin: Date? = nil
  ) async throws {
    guard let snap = try await d.store.requestSnapshot(id) else { throw GenerationError.requestNotFound }
    guard let key = try? d.keyStore.read(), !key.isEmpty else { throw PrepareError.noAPIKey }
    let bodyURL = d.files.bodyURL(id)
    var size = Self.fileSize(bodyURL)
    if rebuildBody || size == 0 || categories != nil {
      let body = try await preparer.prepare(
        snap, parent: action, reuseRecorded: reuseRecorded || snap.selectionReason == .attachments, categories: categories)
      size = body.size
    }
    try Task.checkCancellation()
    let fresh = try await d.store.requestSnapshot(id) ?? snap
    try await startAttempt(
      fresh, action: action, attempt: fresh.attempt + 1, bodyURL: bodyURL, bodySize: size, earliestBegin: earliestBegin,
      apiKey: key, createdInBackground: earliestBegin != nil && !d.activity.isActive)
  }

  /// Persists the attempt, begins its Attempt sub-action, then starts the task. The state is saved
  /// before the task exists, so a fast completion can't be overwritten afterwards.
  private func startAttempt(
    _ snap: RequestSnapshot, action: ActionID, attempt: Int, bodyURL: URL, bodySize: Int, earliestBegin: Date?,
    apiKey: String, createdInBackground: Bool
  ) async throws {
    let now = d.clock()
    try await d.store.updateRequest(snap.id) { p in
      p.attempt = attempt
      p.state = earliestBegin == nil ? .inFlight : .retryScheduled
      p.startedAt = now
      p.nextAttemptAt = .some(earliestBegin)
      p.nextAttemptCreatedInBackground = createdInBackground
      p.taskIdentifier = .some(nil)
    }
    let expected = expectedReceiveBytes(imageSize: snap.settings.imageSize)
    let begin = earliestBegin.map { " · earliest begin in \(Format.seconds(.seconds(max(0, $0.timeIntervalSince(now)))))" } ?? ""
    let attemptAction = d.log.begin(
      "Attempt \(attempt)", parent: action,
      "POST /v1beta/models/\(GeminiEndpoint.pathSegment(snap.settings.modelID)):generateContent · body \(Format.mb(bodySize)) · \(d.sessionDescription) · timeouts 300 s idle, 1800 s total\(begin) · expect ~\(expected / 1_000_000) MB"
    )
    attemptActions[snap.id] = attemptAction
    let job = TransportJob(
      requestID: snap.id, attempt: attempt, modelID: snap.settings.modelID, bodyURL: bodyURL, bodySize: bodySize,
      expectedReceiveBytes: expected, earliestBegin: earliestBegin)
    let taskID: Int
    do {
      taskID = try d.transport.start(job, apiKey: apiKey)
    } catch {
      attemptActions[snap.id] = nil
      d.log.result(attemptAction, .failed, "couldn't create the task: \(error.localizedDescription)")
      throw error
    }
    d.log.step(attemptAction, "upload task \(taskID) \(earliestBegin == nil ? "resumed" : "scheduled")")
    try? await d.store.updateRequest(snap.id) { $0.taskIdentifier = .some(taskID) }
  }

  // MARK: Events

  private func handle(_ event: TransportEvent) async {
    switch event {
    case .began(let requestID, let attempt, let taskIdentifier):
      guard let snap = try? await d.store.requestSnapshot(requestID), snap.attempt == attempt,
        snap.state == .retryScheduled
      else { return }
      try? await d.store.updateRequest(requestID) { p in
        p.state = .inFlight
        p.startedAt = self.d.clock()
        p.taskIdentifier = .some(taskIdentifier)
      }
      if let att = attemptActions[requestID] { d.log.step(att, "task \(taskIdentifier) began") }
    case .completed(let completion):
      completionsSinceFinished += 1
      await handleCompleted(completion, reparse: false)
    case .finishedEvents(let id):
      let handled = completionsSinceFinished
      completionsSinceFinished = 0
      await d.onBackgroundEventsFinished(id, handled)
    }
  }

  private func handleCompleted(_ c: TransportCompletion, reparse: Bool) async {
    if replacedTasks.remove(c.taskIdentifier) != nil { return }
    let id = c.requestID
    guard let snap = try? await d.store.requestSnapshot(id) else {
      // The record was deleted (with its chat or message): discard the result and its files.
      try? FileManager.default.removeItem(at: d.files.requestDir(id))
      if let att = attemptActions.removeValue(forKey: id) { d.log.result(att, .cancelled, "the request was deleted") }
      if let action = actions[id] { d.log.result(action, .cancelled, "the request was deleted") }
      forget(id, conversation: conversationOf[id])
      return
    }
    guard c.attempt == snap.attempt else { return }
    guard snap.state.isLive || snap.state == .interrupted else { return }

    let isLate = snap.state == .interrupted
    let action: ActionID
    if isLate {
      let original = snap.activityActionID ?? ActionID(raw: "0000")
      action = d.log.beginLateCompletion(
        of: original,
        "req \(Format.short(id)) · original \(original) · marked interrupted · attempt \(c.attempt) · \(c.httpStatus.map { "HTTP \($0)" } ?? "no HTTP status")"
      )
      lateActions[id] = action
    } else {
      action = actionFor(snap)
      if actions[id] == nil {
        actions[id] = action
        d.log.step(action, reparse ? "relaunched; re-parsing the saved response" : "relaunched; continuing with attempt \(c.attempt)")
      }
    }

    // Close the attempt.
    let (attemptOutcome, attemptSummary) = Self.describeAttempt(c, userCancelled: userCancelled.contains(id))
    if !isLate && !reparse { closeAttempt(snap, action: action, outcome: attemptOutcome, attemptSummary) }
    if !d.activity.isActive && !reparse { d.log.step(action, "delivered while the app was in the background") }

    if c.error == .cancelled {
      if userCancelled.remove(id) != nil {
        try? await d.store.updateRequest(id) { p in
          p.state = .cancelled
          p.completedAt = self.d.clock()
        }
        await finish(id, outcome: .cancelled, summary: "stopped by the user\(durationSuffix(id))", notify: false)
      } else {
        let reason = Self.cancelReasonText(c.cancelReason)
        try? await d.store.updateRequest(id) { p in
          p.state = .interrupted
          p.completedAt = self.d.clock()
        }
        await finish(id, outcome: .interrupted, summary: "cancelled by the system (\(reason))", notify: false)
      }
      return
    }

    let errorBody: GeminiErrorBody? =
      c.httpStatus.map { !(200..<300).contains($0) } == true ? (try? Data(contentsOf: c.partURL)).flatMap(GeminiErrorBody.decode) : nil
    let result: AttemptResult =
      c.error.map { .transport($0, elapsed: c.elapsed) }
      ?? .http(status: c.httpStatus ?? 0, headers: c.headers, bodyBytes: c.bytesReceived, error: errorBody)
    let decision =
      isLate
      ? .finish
      : d.retryPolicy.decide(
        result, autoRetriesUsed: snap.autoRetriesUsed, civicWasSent: snap.settings.categories.contains(.civicIntegrity),
        civicFallbackUsed: snap.civicFallbackUsed)

    switch decision {
    case .retry(let delay):
      d.log.step(
        action,
        "auto-retry \(snap.autoRetriesUsed + 1)/\(snap.maxAutoRetries) in \(Format.seconds(delay)): \(Self.retryReason(c, errorBody))")
      await scheduleAutoRetry(snap, action: action, delay: delay)
    case .rebuildWithoutCivicAndRetry:
      let four = snap.settings.categories.filter { $0 != .civicIntegrity }
      d.log.step(action, "CIVIC rebuild: \(four.count) categories (HTTP 400 rejected HARM_CATEGORY_CIVIC_INTEGRITY)")
      try? await d.store.updateRequest(id) { $0.civicFallbackUsed = true }
      await d.setOmitCivicOnMain()
      do {
        try await prepareAndStart(id, action: action, reuseRecorded: true, rebuildBody: true, categories: four)
      } catch {
        let prepError = error as? PrepareError
        await finishFailed(id, status: prepError?.status ?? .network, message: prepError?.message ?? Self.describeError(error))
      }
    case .finish:
      if let code = c.error {
        let timedOut = code == .timedOut
        let message =
          timedOut
          ? "No response within \(c.elapsed >= d.retryPolicy.resourceTimeout ? 30 : 5) min." : Format.urlError(code)
        if snap.autoRetriesUsed >= snap.maxAutoRetries && RetryPolicy.isRetryable(code) {
          d.log.step(action, "no auto-retry: budget used (\(snap.autoRetriesUsed)/\(snap.maxAutoRetries))")
        } else {
          d.log.step(action, "no auto-retry: \(Format.urlError(code)) after \(Format.seconds(c.elapsed)) is not retryable")
        }
        await finishFailed(id, status: timedOut ? .timedOut : .network, message: message)
        return
      }
      if let status = c.httpStatus, !(200..<300).contains(status) {
        let retryable = RetryPolicy.retryableStatuses.contains(status)
        d.log.step(
          action,
          retryable
            ? "no auto-retry: budget used (\(snap.autoRetriesUsed)/\(snap.maxAutoRetries))"
            : "no auto-retry: HTTP \(status) is not retryable")
      } else if c.bytesReceived == 0 && !isLate {
        d.log.step(action, "no auto-retry: budget used (\(snap.autoRetriesUsed)/\(snap.maxAutoRetries))")
      }
      await parse(c, snap: snap, action: action)
    }
  }

  private func scheduleAutoRetry(_ snap: RequestSnapshot, action: ActionID, delay: Duration) async {
    let begin = d.clock().addingTimeInterval(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
    try? await d.store.updateRequest(snap.id) { $0.autoRetriesUsed = snap.autoRetriesUsed + 1 }
    do {
      try await prepareAndStart(
        snap.id, action: action, reuseRecorded: true, rebuildBody: false, categories: nil, earliestBegin: begin)
    } catch {
      let prepError = error as? PrepareError
      await finishFailed(snap.id, status: prepError?.status ?? .network, message: prepError?.message ?? Self.describeError(error))
    }
  }

  // MARK: Parsing and saving

  private func parse(_ c: TransportCompletion, snap: RequestSnapshot, action: ActionID) async {
    let id = snap.id
    let status = c.httpStatus ?? 200
    try? await d.store.updateRequest(id) { $0.state = .parsing }
    let parseStarted = ContinuousClock.now
    let parseAction = d.log.begin(
      "Parse", parent: action, "HTTP \(status) · response-\(c.attempt).part \(Format.mb(c.bytesReceived))")

    let outcome: ParsedOutcome
    do {
      outcome = try await ResponseParser.parse(
        httpStatus: status, bodyURL: c.partURL, outputDirectory: d.files.outputDir(id, attempt: c.attempt))
    } catch {
      d.log.result(parseAction, .failed, "in \(Format.seconds(ContinuousClock.now - parseStarted)) · couldn't save an image: \(error.localizedDescription)")
      await finishFailed(
        id, status: RequestPreparer.isDiskFull(error) ? .diskFull : .malformed,
        message: RequestPreparer.isDiskFull(error) ? "Not enough storage to save the result" : error.localizedDescription,
        httpStatus: status)
      return
    }
    let took = "in \(Format.seconds(ContinuousClock.now - parseStarted))"
    let now = d.clock()

    switch outcome {
    case .success(let parts, let finishReason, let notices, let modelVersion, let responseID, let details):
      do {
        let (messageParts, images) = try moveImages(parts, conversation: snap.conversationID)
        var patch = RequestPatch()
        patch.state = .succeeded
        patch.completedAt = now
        patch.httpStatus = status
        patch.finishReason = finishReason
        patch.modelVersion = modelVersion
        patch.responseID = responseID
        patch.details = details
        patch.outputWidth = images.first?.pixelWidth
        patch.outputHeight = images.first?.pixelHeight
        try await d.store.completeReply(requestID: id, parts: messageParts, images: images, notices: notices, outcomeFields: patch)
        let summary = Self.describeParts(parts, finishReason: finishReason, notices: notices)
        d.log.result(parseAction, .success, "\(took) · \(summary)")
        d.log.step(
          action,
          "saved reply: \(images.count) image\(images.count == 1 ? "" : "s"), \(messageParts.count - images.count) text run\(messageParts.count - images.count == 1 ? "" : "s"); request succeeded"
        )
        warmThumbnails(images)
        let text = parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.first
        await finish(
          id, outcome: .success, summary: "\(durationPrefix(id))HTTP \(status) · \(summary)\(attemptsSuffix(c.attempt))",
          body: NotificationPoster.body(state: .succeeded, imageCount: images.count, text: text, refusalReason: nil, failure: nil))
      } catch {
        d.log.result(parseAction, .failed, "\(took) · couldn't save the reply: \(error.localizedDescription)")
        await finishFailed(
          id, status: RequestPreparer.isDiskFull(error) ? .diskFull : .malformed,
          message: RequestPreparer.isDiskFull(error) ? "Not enough storage to save the result" : error.localizedDescription,
          httpStatus: status)
      }

    case .refused(let reason, let message, let notices, let details):
      try? await d.store.updateRequest(id) { p in
        p.state = .refused
        p.completedAt = now
        p.httpStatus = status
        p.refusalReason = reason
        p.errorMessage = message
        p.details = details
        p.notices = notices
      }
      d.log.result(parseAction, .refused, "\(reason) · \(took)")
      await finish(
        id, outcome: .refused, summary: "\(reason) · HTTP \(status)\(durationSuffix(id))\(attemptsSuffix(c.attempt))",
        body: NotificationPoster.body(state: .refused, imageCount: 0, text: nil, refusalReason: reason, failure: nil))

    case .empty(let finishReason, let details):
      try? await d.store.updateRequest(id) { p in
        p.state = .failed
        p.completedAt = now
        p.httpStatus = status
        p.errorStatus = LocalErrorStatus.empty.rawValue
        p.finishReason = finishReason
        p.details = details
      }
      let finish = finishReason ?? "none"
      d.log.result(parseAction, .failed, "empty reply · finish \(finish) · \(took)")
      await self.finish(
        id, outcome: .failed, summary: "empty reply · finish \(finish) · HTTP \(status)\(durationSuffix(id))",
        body: NotificationPoster.body(state: .failed, imageCount: 0, text: nil, refusalReason: nil, failure: "no content returned"))

    case .apiError(let http, let rpcStatus, let message, let details):
      let label = rpcStatus.map { "HTTP \(http) \($0)" } ?? "HTTP \(http)"
      try? await d.store.updateRequest(id) { p in
        p.state = .failed
        p.completedAt = now
        p.httpStatus = http
        if let rpcStatus { p.errorStatus = rpcStatus }
        p.errorMessage = message
        p.details = details
      }
      // A JSON error logs its message; any other body logs its first 2 KB with a note of the cut.
      let raw = (try? Data(contentsOf: c.partURL)) ?? Data()
      let logged = Redactor.errorBodyForLog(
        GeminiErrorBody.decode(raw) == nil ? String(decoding: raw, as: UTF8.self) : message)
      d.log.result(parseAction, .failed, "\(label): \(private: logged) · \(took)")
      await finish(
        id, outcome: .failed,
        summary: "\(label): \(private: logged)\(durationSuffix(id))\(attemptsSuffix(c.attempt))",
        body: NotificationPoster.body(
          state: .failed, imageCount: 0, text: nil, refusalReason: nil, failure: "Error \(http)\(rpcStatus.map { " \($0)" } ?? "")"))

    case .malformed(let details):
      try? await d.store.updateRequest(id) { p in
        p.state = .failed
        p.completedAt = now
        p.httpStatus = status
        p.errorStatus = LocalErrorStatus.malformed.rawValue
        p.details = details
      }
      d.log.result(parseAction, .failed, "malformed body · \(took)")
      await finish(
        id, outcome: .failed, summary: "unexpected response · HTTP \(status)\(durationSuffix(id))",
        body: NotificationPoster.body(state: .failed, imageCount: 0, text: nil, refusalReason: nil, failure: "unexpected response"))
    }
  }

  /// Moves parsed images into `Images/<conv>/` (a rename on the same volume) and builds the parts.
  private func moveImages(_ parts: [OutputPart], conversation: UUID) throws -> ([MessagePart], [ReplyImage]) {
    var messageParts: [MessagePart] = []
    var images: [ReplyImage] = []
    for part in parts {
      switch part {
      case .text(let t):
        messageParts.append(MessagePart(kind: .text, text: t, imageID: nil))
      case .image(let img):
        let imageID = UUID()
        let ext = MimeTypes.fileExtension(for: img.mimeType)
        let relative = d.files.imageRelativePath(conv: conversation, image: imageID, ext: ext)
        try d.files.moveStaged(img.fileURL, to: d.files.url(relative: relative))
        images.append(
          ReplyImage(
            id: imageID, relativePath: relative, mimeType: img.mimeType, byteCount: img.byteCount, pixelWidth: img.pixelWidth,
            pixelHeight: img.pixelHeight))
        messageParts.append(MessagePart(kind: .image, text: nil, imageID: imageID))
      }
    }
    return (messageParts, images)
  }

  private func warmThumbnails(_ images: [ReplyImage]) {
    guard let thumbnails = d.thumbnails, !images.isEmpty else { return }
    let files = d.files
    Task.detached(priority: .utility) {
      for image in images {
        for px in [ThumbnailService.listSize, ThumbnailService.bubbleSize] {
          _ = await thumbnails.thumbnail(for: files.url(relative: image.relativePath), id: image.id, px: px)
        }
      }
    }
  }

  // MARK: Finishing

  private func finishFailed(_ id: UUID, status: LocalErrorStatus, message: String, httpStatus: Int? = nil) async {
    try? await d.store.updateRequest(id) { p in
      p.state = .failed
      p.completedAt = self.d.clock()
      p.errorStatus = status.rawValue
      p.errorMessage = message
      if let httpStatus { p.httpStatus = httpStatus }
    }
    let attempts = (try? await d.store.requestSnapshot(id))?.attempt ?? 0
    await finish(
      id, outcome: .failed, summary: "\(status.rawValue): \(message)\(durationSuffix(id))\(attemptsSuffix(attempts))",
      body: NotificationPoster.body(state: .failed, imageCount: 0, text: nil, refusalReason: nil, failure: message))
  }

  /// Notifies (unless suppressed), writes the action's one result, and releases the chat.
  private func finish(_ id: UUID, outcome: ActivityOutcome, summary: ActivityMessage, body: String? = nil, notify: Bool = true) async {
    let conversation: UUID? = await conversationID(of: id)
    let action = lateActions[id] ?? actions[id]
    if action != nil, let attempt = attemptActions.removeValue(forKey: id) {
      d.log.result(attempt, outcome, "closed with the request")
    }
    if notify, let body, let conversation, let action {
      let title = (try? await d.store.conversationTitle(conversation)) ?? Conversation.untitled
      let result = await d.notifier.post(ReplyNotification(conversationID: conversation, title: title, body: body))
      d.log.step(action, "\(result.logText)")
    }
    if let action { d.log.result(action, outcome, summary) }
    forget(id, conversation: conversation)
  }

  private func forget(_ id: UUID, conversation: UUID?) {
    if let conversation { busyConversations.remove(conversation) }
    actions[id] = nil
    lateActions[id] = nil
    attemptActions[id] = nil
    startedAt[id] = nil
    conversationOf[id] = nil
    preparations[id] = nil
  }

  private func conversationID(of id: UUID) async -> UUID? {
    if let c = conversationOf[id] { return c }
    return (try? await d.store.requestSnapshot(id))?.conversationID
  }

  private func claim(_ conv: UUID) async throws {
    if busyConversations.contains(conv) { throw GenerationError.chatBusy }
    busyConversations.insert(conv)
    if (try? await d.store.hasLiveRequest(conv: conv)) == true {
      busyConversations.remove(conv)
      throw GenerationError.chatBusy
    }
  }

  /// The action following a request: this process's, or the one recorded on it (adopted).
  private func actionFor(_ snap: RequestSnapshot) -> ActionID {
    actions[snap.id] ?? snap.activityActionID ?? ActionID(raw: "0000")
  }

  private func closeAttempt(_ snap: RequestSnapshot, action: ActionID, outcome: ActivityOutcome, _ summary: ActivityMessage) {
    if let att = attemptActions.removeValue(forKey: snap.id) {
      d.log.result(att, outcome, summary)
    } else if snap.attempt > 0 {
      d.log.result(ofOpenChild: "Attempt \(snap.attempt)", of: action, outcome, summary)
    }
  }

  // MARK: Descriptions (D§4.13 Messages)

  private func durationPrefix(_ id: UUID) -> String {
    startedAt[id].map { "in \(Format.seconds(ContinuousClock.now - $0)) · " } ?? ""
  }

  private func durationSuffix(_ id: UUID) -> String {
    startedAt[id].map { " in \(Format.seconds(ContinuousClock.now - $0))" } ?? ""
  }

  private func attemptsSuffix(_ attempts: Int) -> String {
    attempts > 1 ? " · attempts \(attempts)" : ""
  }

  /// `gemini-3.1-flash-image · 16:9 · 2K · safety BLOCK_NONE · modalities TEXT+IMAGE · categories 5`, plus coercions.
  private func describe(_ s: EffectiveSettings) -> String {
    var parts = [
      s.modelID, s.aspectRatio?.rawValue ?? "aspect omitted", s.imageSize?.rawValue ?? "size omitted",
      "safety \(s.threshold.rawValue)", "modalities \(s.includeTextModality ? "TEXT+IMAGE" : "IMAGE")",
      "categories \(s.categories.count)\(s.categories.contains(.civicIntegrity) ? "" : " (CIVIC_INTEGRITY omitted)")",
    ]
    for c in s.coercions {
      let field = switch c.field {
      case .model: "model"
      case .aspectRatio: "aspect"
      case .imageSize: "size"
      }
      parts.append("\(field) \(c.requested) → \(c.used ?? "omitted")")
    }
    return parts.joined(separator: " · ")
  }

  private func describeInputs(_ selection: Selection, attachments: [StagedAttachment], reused: [InputSnapshot]) -> String {
    switch selection.reason {
    case .noImage:
      return "none"
    case .attachments:
      let items = attachments.map { a in
        "upload img \(Format.short(a.id)), \(Format.image(width: a.pixelWidth, height: a.pixelHeight, mimeType: a.originalMimeType, bytes: a.originalByteCount)) → sent \(Format.image(width: a.prepared.pixelWidth, height: a.prepared.pixelHeight, mimeType: a.prepared.mimeType, bytes: a.prepared.byteCount))"
      }
      return "attachments (\(items.joined(separator: "; ")))"
    case .pinned, .latest:
      let edge = d.defaults().maxUploadLongEdge
      let items = reused.map { describeReused($0, edge: edge) }
      return "\(selection.reason.rawValue) (\(items.joined(separator: "; ")))"
    }
  }

  private func describeReused(_ s: InputSnapshot, edge: Int) -> String {
    let url = d.files.url(relative: s.originalRelativePath)
    let info = try? ImageInspector.inspect(url: url)
    let original = Format.image(
      width: info?.orientedWidth ?? 0, height: info?.orientedHeight ?? 0, mimeType: s.originalMimeType,
      bytes: Self.fileSize(url))
    if s.origin == .model {
      return "model output img \(Format.short(s.imageID)), \(original), sent as original"
    }
    if let p = s.prepared, s.preparedLongEdgeSetting == edge, d.files.exists(relative: p.preparedRelativePath) {
      return "upload img \(Format.short(s.imageID)), \(original) → sent \(Format.image(width: p.pixelWidth, height: p.pixelHeight, mimeType: p.mimeType, bytes: p.byteCount))"
    }
    return "upload img \(Format.short(s.imageID)), \(original) → prepare at \(edge)"
  }

  private func describeRecorded(_ snap: RequestSnapshot) -> String {
    if snap.inputs.isEmpty { return "none" }
    let origins = Dictionary(snap.inputAssets.map { ($0.imageID, $0.origin) }, uniquingKeysWith: { a, _ in a })
    let items = snap.inputs.map { i in
      "\(origins[i.imageID] == .model ? "model output" : "upload") img \(Format.short(i.imageID)), sent \(Format.image(width: i.pixelWidth, height: i.pixelHeight, mimeType: i.mimeType, bytes: i.byteCount))"
    }
    return "\(snap.selectionReason.rawValue) (\(items.joined(separator: "; ")))"
  }

  static func quoted(_ prompt: String) -> String { "\"\(prompt)\"" }

  static func describeParts(_ parts: [OutputPart], finishReason: String?, notices: [String]) -> String {
    var out: [String] = []
    let images = parts.compactMap { if case .image(let i) = $0 { i } else { nil } }
    let texts = parts.compactMap { if case .text(let t) = $0 { t } else { nil } }
    if images.isEmpty {
      out.append("no image")
    } else {
      out.append(
        "\(images.count) image\(images.count == 1 ? "" : "s") "
          + images.map { Format.image(width: $0.pixelWidth, height: $0.pixelHeight, mimeType: $0.mimeType, bytes: $0.byteCount) }
          .joined(separator: ", "))
    }
    if !texts.isEmpty {
      out.append("\(texts.count) text run\(texts.count == 1 ? "" : "s") (\(texts.map { "\($0.count) chars" }.joined(separator: ", ")))")
    }
    out.append("finish \(finishReason ?? "none")")
    out.append(contentsOf: notices)
    return out.joined(separator: " · ")
  }

  static func describeAttempt(_ c: TransportCompletion, userCancelled: Bool) -> (ActivityOutcome, ActivityMessage) {
    let took = "in \(Format.seconds(c.elapsed))"
    if let code = c.error {
      if code == .cancelled {
        return userCancelled
          ? (.cancelled, "\(took) · cancelled by the user")
          : (.interrupted, "\(took) · cancelled by the system (\(cancelReasonText(c.cancelReason)))")
      }
      return (.failed, "\(took) · URLError \(Format.urlError(code)) · received \(Format.mb(c.bytesReceived))")
    }
    let status = c.httpStatus ?? 0
    return (
      (200..<300).contains(status) ? .success : .failed, "\(took) · HTTP \(status) · received \(Format.mb(c.bytesReceived))"
    )
  }

  static func retryReason(_ c: TransportCompletion, _ error: GeminiErrorBody?) -> String {
    if let code = c.error { return "URLError \(Format.urlError(code)) after \(Format.seconds(c.elapsed))" }
    let status = c.httpStatus ?? 0
    if (200..<300).contains(status) { return "empty HTTP \(status) body" }
    var reason = "HTTP \(status)\(error?.status.map { " \($0)" } ?? "")"
    if let delay = error?.retryDelay {
      reason += " (RetryInfo \(Int(delay.components.seconds))s)"
    } else if let after = RetryPolicy.retryAfter(c.headers) {
      reason += " (Retry-After \(Int(after.components.seconds)))"
    }
    return reason
  }

  static func cancelReasonText(_ reason: Int?) -> String {
    switch reason {
    case NSURLErrorCancelledReasonUserForceQuitApplication: "reason: force quit"
    case NSURLErrorCancelledReasonBackgroundUpdatesDisabled: "reason: background updates disabled"
    case NSURLErrorCancelledReasonInsufficientSystemResources: "reason: insufficient system resources"
    case let r?: "reason \(r)"
    case nil: "no reason given"
    }
  }

  static func describeError(_ error: any Error) -> String {
    (error as? PrepareError)?.message ?? error.localizedDescription
  }

  static func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }
}
