import Foundation

/// Service interface coordinating multimodal image generation requests.
/// Conforms to `Sendable` to enable invocation across main actor view models and background task contexts.
protocol GenerationServicing: Sendable {
  func send(_ d: SendDraft) async throws -> UUID
  func regenerate(sourceRequestID: UUID) async throws -> UUID
  func retry(requestID: UUID) async throws
  func cancel(requestID: UUID) async
}

/// Synchronous validation and dispatch errors thrown to presentation callers.
enum GenerationError: Error, Equatable {
  /// Generation request already in flight for the target conversation.
  case chatBusy
  /// Associated conversation or request record was deleted.
  case requestNotFound
  /// Request state does not permit retry.
  case notRetryable(RequestState)
  /// Prerequisite input media is missing from storage.
  case inputMissing
  /// Pre-flight request serialization or media downscaling failed.
  case preparationFailed(LocalErrorStatus)
  /// Background execution assertion expired prior to network task dispatch.
  case interrupted
  /// Request execution was cancelled by the user prior to network task materialization.
  case cancelled
}

/// Core orchestrator managing generation request state transitions, background task assertions,
/// and transport event processing.
///
/// GenerationService consumes the transport layer's serialized event stream, maintains relational
/// request states in `DataStore`, and executes structured activity logging across request preparation,
/// attempt transport, and response parsing phases.
///
/// As an actor, `GenerationService` guarantees serialized access between suspension points.
/// Because actor execution is reentrant across asynchronous suspensions (e.g., storage I/O,
/// payload encoding, and response parsing), state consistency is maintained through invariants:
/// - Per-Entity Mutual Exclusion (`exclusive(_:_:)`): Serializes all state mutations for a given request ID
///   using FIFO continuation queues, preventing concurrent processing between transport completions,
///   user-initiated retries, and launch reconciliation.
/// - Scoped Conversation Claims (`claim`, `release`): Enforces a single active request per conversation,
///   bridging the latency window between user input dispatch and persistent record creation via unique tokens.
/// - Persistent Cancellation Signals (`userCancelled`): Caches cooperative cancellation flags to ensure
///   early user stop actions take effect even if received prior to task materialization.
/// - Atomic Assertion Ownership (`Preparation`): Coordinates race resolution between main-thread background
///   expiration handlers and asynchronous preparation pipelines under mutual exclusion locks.
/// - Monotonic Attempt Isolation: Binds transport tasks and event streams to specific attempt indices,
///   discarding late events originating from cancelled or superseded attempts.
actor GenerationService: GenerationServicing {
  /// Parameterized subsystem dependencies injected at composition root.
  struct Dependencies: Sendable {
    var transport: any GenerationTransport
    var store: DataStore
    var files: FileStore
    var keyStore: any APIKeyStore
    var log: ActivityLog
    var backgroundTasks: any BackgroundTaskProviding
    var notifier: any NotificationPosting
    var activity: AppActivity
    /// Warm thumbnail cache for completed generation replies.
    var thumbnails: ThumbnailService?
    var retryPolicy = RetryPolicy()
    /// Closure querying current generation settings defaults without hopping to the main actor.
    var defaults: @Sendable () -> GenerationDefaults
    /// Mutates `AppSettings.omitCivicIntegrity` on the main actor upon API category deprecation errors.
    var setOmitCivicOnMain: @Sendable () async -> Void
    /// Invokes system completion callback following background URLSession wake delivery.
    var onBackgroundEventsFinished: @Sendable (_ sessionID: String, _ completionsHandled: Int) async -> Void
    var sessionDescription = "background session"
    var shrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor
    var budget = BudgetPlanner.budget
    var clock: @Sendable () -> Date = { Date() }
  }

  /// Thread safe state coordinator managing the lifecycle of an inflight request preparation.
  ///
  /// Arbitrates terminal result ownership between UIKit background task expiration handlers
  /// executing synchronously on the main thread and asynchronous preparation tasks running within the actor.
  final class Preparation: Sendable {
    enum Phase: Sendable { case preparing, sending, finished, expired }
    let phase = Locked(Phase.preparing)
    let task = Locked<Task<Void, any Error>?>(nil)

    var expired: Bool { phase.value == .expired }
    func cancel() { task.value?.cancel() }

    /// Invoked by background expiration handler.
    /// Returns true if expiration owns the terminal result.
    func claimExpiry() -> Bool {
      phase.withLock { p in
        guard p == .preparing else { return false }
        p = .expired
        return true
      }
    }

    /// Invoked immediately prior to network task dispatch.
    /// Returns true if preparation has not expired.
    func claimSending() -> Bool {
      phase.withLock { p in
        if p == .preparing { p = .sending }
        return p == .sending
      }
    }

    /// Invoked upon preparation completion.
    /// Returns false if expiration handler already finalized the request.
    func claimFinish() -> Bool {
      phase.withLock { p in
        guard p != .expired else { return false }
        p = .finished
        return true
      }
    }
  }

  /// Thread safe reference holder for the event consumer task.
  private final class ConsumerBox: Sendable {
    let task = Locked<Task<Void, Never>?>(nil)
  }

  private let d: Dependencies
  private let preparer: RequestPreparer
  private let consumer = ConsumerBox()

  // The properties below are the actor's in-memory state. Only the actor reads or writes them, but a
  // value read before an `await` can be different after it. The record in `DataStore` is the source
  // of truth. This state only covers the current process and is rebuilt after a relaunch.

  /// Chats with a send between the tap and the request record's creation, each with the token of
  /// the call that claimed it: only that call releases it.
  private var busyConversations: [UUID: UUID] = [:]
  /// requestID → its chat, for the notification; `conversationID(of:)` falls back to the store.
  private var conversationOf: [UUID: UUID] = [:]
  /// Request-to-action identifier mapping for ongoing activity logging within this process.
  private var actions: [UUID: ActionID] = [:]
  /// Separate activity tracking for late arriving completions following an interruption.
  private var lateActions: [UUID: ActionID] = [:]
  /// Active attempt sub-actions indexed by request ID.
  private var attemptActions: [UUID: ActionID] = [:]
  /// Wall clock start times captured for duration metrics.
  private var startedAt: [UUID: ContinuousClock.Instant] = [:]
  /// Cooperative cancellation registry preserving user stop requests across lifecycle transitions.
  private var userCancelled: Set<UUID> = []
  /// Active preparation instances tracking inflight preparation before network dispatch.
  private var preparations: [UUID: Preparation] = [:]
  /// Tally of background-delivered completions awaiting system completion acknowledgment.
  private var completionsSinceFinished = 0
  /// Continuation wait-queues enforcing per-request serial execution turns.
  private var requestLocks: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  /// Serializes consecutive foreground retry re-creation passes.
  private var reactivation: Task<Void, Never>?

  init(_ dependencies: Dependencies) {
    d = dependencies
    preparer = RequestPreparer(
      files: dependencies.files, store: dependencies.store, log: dependencies.log, defaults: dependencies.defaults,
      shrink: dependencies.shrink, budget: dependencies.budget)
    // Initiates the asynchronous event consumer loop, ingesting transport completions from background wakes.
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

  /// Cancels the transport event consumption loop, utilized for testing lifecycle restarts.
  nonisolated func stop() {
    consumer.task.value?.cancel()
  }

  /// Registers and dispatches a new generation request from composer input drafts.
  /// Throws `chatBusy` if an existing request is currently in progress for the specified conversation.
  func send(_ draft: SendDraft) async throws -> UUID {
    let conv = draft.conversationID
    let claim = try await claim(conv)
    defer { release(conv, claim) }

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
    await d.log.flush(timeout: .seconds(1))
    let started = ContinuousClock.now

    let input = SendRecordInput(
      conversationID: conv, promptText: draft.promptText, attachments: draft.attachments, selection: selection,
      settings: draft.settings, activityActionID: action)
    return try await prepareWithAssertion(
      action: action, conversation: conv, claim: claim, started: started, reuseRecorded: false
    ) {
      let record = try await self.d.store.createSend(input)
      return record.requestID
    }
  }

  /// Clones and executes a previously recorded request using its captured inputs and parameters.
  func regenerate(sourceRequestID: UUID) async throws -> UUID {
    guard let source = try await d.store.requestSnapshot(sourceRequestID) else { throw GenerationError.requestNotFound }
    let conv = source.conversationID
    let claim = try await claim(conv)
    defer { release(conv, claim) }

    let action = d.log.begin(
      "Regenerate", origin: .user,
      "source req \(Format.short(sourceRequestID)) · recorded values reused · \(describe(source.settings)) · input \(describeRecorded(source)) · chat \(Format.short(conv)) · prompt \(private: Self.quoted(source.promptText))"
    )
    await d.log.flush(timeout: .seconds(1))
    let started = ContinuousClock.now
    let omitCivic = d.defaults().omitCivicIntegrity && source.settings.categories.contains(.civicIntegrity)
    return try await prepareWithAssertion(
      action: action, conversation: conv, claim: claim, started: started, reuseRecorded: true,
      categories: omitCivic ? source.settings.categories.filter { $0 != .civicIntegrity } : nil
    ) {
      guard let record = try await self.d.store.createRegenerate(sourceRequestID: sourceRequestID, activityActionID: action)
      else { throw PrepareError.inputMissing }
      if omitCivic { self.d.log.step(action, "CIVIC_INTEGRITY omitted since the original: 4 categories") }
      return record.requestID
    }
  }

  /// Reschedules an interrupted or failed request under its original identity, resetting retry quotas.
  func retry(requestID: UUID) async throws {
    guard let snap = try await d.store.requestSnapshot(requestID) else { throw GenerationError.requestNotFound }
    guard Self.retryable.contains(snap.state) else { throw GenerationError.notRetryable(snap.state) }
    let conv = snap.conversationID
    let claim = try await claim(conv)
    defer { release(conv, claim) }

    let action = d.log.begin(
      "Retry", origin: .user,
      "req \(Format.short(requestID)) · attempt \(snap.attempt + 1) · auto-retry budget reset · \(describe(snap.settings)) · input \(describeRecorded(snap)) · prompt \(private: Self.quoted(snap.promptText))"
    )
    await d.log.flush(timeout: .seconds(1))
    let started = ContinuousClock.now
    _ = try await prepareWithAssertion(
      action: action, conversation: conv, claim: claim, started: started, reuseRecorded: true,
      rebuildBody: !FileManager.default.fileExists(atPath: d.files.bodyURL(requestID).path)
    ) {
      try await self.beginRetry(requestID, action: action)
      return requestID
    }
  }

  /// The terminal states that offer Retry. `succeeded` is the only terminal state that doesn't.
  static let retryable: Set<RequestState> = [.failed, .refused, .cancelled, .interrupted]

  /// Moves a finished request back to `preparing` for a Retry, in its turn: a late completion
  /// being saved at this moment finishes first, and the state is checked again afterwards.
  /// Without the turn, a late success and the Retry could both write the record, and the Retry could
  /// replace a reply that had just arrived. The attempt number stays; `startAttempt` increments it.
  private func beginRetry(_ id: UUID, action: ActionID) async throws {
    try await exclusive(id) {
      guard let snap = try await d.store.requestSnapshot(id) else { throw GenerationError.requestNotFound }
      guard Self.retryable.contains(snap.state) else { throw GenerationError.notRetryable(snap.state) }
      // A Stop of an earlier attempt doesn't carry over to this one.
      userCancelled.remove(id)
      // Clear optional attributes via `.some(nil)` while preserving unmodified fields.
      // Associate the updated record with the current retry action to ensure continuity across relaunches.
      try await d.store.updateRequest(id) { p in
        p.clearOutcome = true
        p.state = .preparing
        p.autoRetriesUsed = 0
        p.nextAttemptAt = .some(nil)
        p.taskIdentifier = .some(nil)
        p.nextAttemptCreatedInBackground = false
        p.activityActionID = action
      }
    }
  }

  /// Cancels an in-flight generation request across any lifecycle stage: request preparation, active network transport,
  /// or scheduled retry backoff. If the underlying request record was deleted concurrently, execution terminates without
  /// opening an independent cancellation activity, as the deletion operation recorded diagnostic context.
  ///
  /// Cancellation does not acquire the per-request serialization lock and avoids writing persistent state directly,
  /// preventing cancellation operations from stalling behind long-running tasks such as response parsing. Terminal state
  /// transition to `.cancelled` is deferred to the executing handler (transport completion, aborted preparation, or start failure).
  /// A cancellation signal received during payload parsing is safely ignored to preserve completed generation output.
  func cancel(requestID: UUID) async {
    let snap: RequestSnapshot?
    do { snap = try await d.store.requestSnapshot(requestID) } catch { return }
    if let snap, !snap.state.isLive { return }
    let action = snap.map {
      d.log.begin("Cancel", origin: .user, "req \(Format.short(requestID)) · state \($0.state.rawValue)")
    }
    // Register cancellation intent prior to any suspension point. Subsequent `startAttempt` calls detect this flag,
    // and network completions returning `NSURLErrorCancelled` transition to `.cancelled` rather than `.interrupted`.
    userCancelled.insert(requestID)
    // For requests restored post-launch, preserve the associated action ID and attempt hierarchy so transport cancellation
    // cleans up telemetry structures even if the request record is deleted concurrently.
    if actions[requestID] == nil, let adopted = snap?.activityActionID {
      actions[requestID] = adopted
      conversationOf[requestID] = snap?.conversationID
    }
    let preparing = preparations[requestID]
    preparing?.cancel()
    // Signal transport cancellation to catch cases where task creation completed immediately prior to cancellation.
    await d.transport.cancel(requestID: requestID)
    // Account for requests transitioning through preparation prior to in-memory registration.
    let wasPreparing = preparing != nil || snap?.state == .preparing
    if let action { d.log.result(action, .success, wasPreparing ? "preparation cancelled" : "task cancelled") }
  }

  /// Recreates in the foreground any retry tasks scheduled while the application was inactive, avoiding system imposed
  /// discretionary background scheduling policies. Consecutive scene activations are serialized to prevent duplicate replacements.
  func appBecameActive() async {
    // Reset background completion tracking relative to foreground activation boundaries.
    completionsSinceFinished = 0
    // Serialize activation passes atomically on the actor to prevent race conditions during rapid scene state transitions.
    let previous = reactivation
    let pass = Task {
      await previous?.value
      await self.recreateBackgroundRetries()
    }
    reactivation = pass
    await pass.value
  }

  private func recreateBackgroundRetries() async {
    guard let pending = try? await d.store.nonTerminalRequests() else { return }
    // Refresh snapshot state within the request-level lock to ensure synchronization against inbound transport completions.
    for snap in pending where snap.state == .retryScheduled && snap.nextAttemptCreatedInBackground {
      // Re-read API credentials from the Keychain for every task creation.
      guard let old = snap.taskIdentifier, let key = try? d.keyStore.read(), !key.isEmpty else { continue }
      await exclusive(snap.id) { await replaceBackgroundRetry(snap.id, oldTask: old, apiKey: key) }
    }
  }

  /// Replaces a single background-scheduled retry task if it remains pending and unstarted. Active transfers or
  /// completions received while suspended retain their results and are processed in order. Must be invoked within `exclusive(_:_:)`.
  private func replaceBackgroundRetry(_ id: UUID, oldTask old: Int, apiKey key: String) async {
    // Validate that the request state, background flag, and task identifier remain unchanged.
    guard let snap = try? await d.store.requestSnapshot(id), snap.state == .retryScheduled,
      snap.nextAttemptCreatedInBackground, snap.taskIdentifier == old
    else { return }
    // Replace only if the system has not initiated data transfer.
    guard let live = await d.transport.liveTasks().first(where: { $0.taskIdentifier == old }), live.countOfBytesSent == 0
    else { return }
    let action = actionFor(snap)
    // Adopt telemetry context to ensure failure handling closes open activities.
    actions[id] = action
    conversationOf[id] = snap.conversationID
    // Cancel the obsolete task prior to initiating replacement to maintain single-task invariants per request.
    await d.transport.cancel(taskIdentifier: old)
    closeAttempt(snap, action: action, outcome: .cancelled, "replaced: re-created in the foreground")
    d.log.step(action, "background-created retry re-created in the foreground")
    // Preserve the original scheduling delay; the new task starts no earlier than the original deadline.
    let begin = max(d.clock(), snap.nextAttemptAt ?? d.clock())
    do {
      // Increment attempt counter so late events from the cancelled task are discarded.
      try await startAttempt(
        snap, action: action, attempt: snap.attempt + 1, bodyURL: d.files.bodyURL(id),
        bodySize: Self.fileSize(d.files.bodyURL(id)), earliestBegin: begin, apiKey: key, createdInBackground: false)
    } catch {
      await finishAfterStartError(id, error, context: "couldn't re-create the retry")
    }
  }

  // The launch reconciliation sequence inspects persistent records and active URLSession tasks once,
  // then invokes these hooks. Each hook acquires the per-request serialization lock and re-verifies state invariants.

  /// Marks an orphaned or interrupted request as interrupted and records telemetry completion.
  /// Requests currently undergoing local preparation are left untouched.
  @discardableResult
  func markInterrupted(_ requestID: UUID, reason: String, expected: (state: RequestState, attempt: Int)? = nil) async
    -> ActionID?
  {
    await exclusive(requestID) {
      // Requests in local preparation are owned by their preparation lifecycle and handled on failure paths.
      guard preparations[requestID] == nil, let snap = try? await d.store.requestSnapshot(requestID), snap.state.isLive
      else { return nil }
      if let expected, snap.state != expected.state || snap.attempt != expected.attempt { return nil }
      return await interrupt(snap, reason: reason)
    }
  }

  /// Transitions a request to `.interrupted`, records its terminal telemetry result, and clears in-memory state.
  /// Must be invoked within `exclusive(_:_:)`.
  private func interrupt(_ snap: RequestSnapshot, reason: String) async -> ActionID {
    try? await d.store.updateRequest(snap.id) { p in
      p.state = .interrupted
      p.completedAt = self.d.clock()
    }
    let action = actionFor(snap)
    closeAttempt(snap, action: action, outcome: .interrupted, "\(reason)")
    d.log.result(action, .interrupted, "\(reason)")
    forget(snap.id)
    return action
  }

  /// Updates task tracking for an active request, transitioning delayed tasks to `.inFlight` once execution begins.
  func refreshLiveTask(_ requestID: UUID, attempt: Int, taskIdentifier: Int, began: Bool) async {
    await exclusive(requestID) {
      guard let snap = try? await d.store.requestSnapshot(requestID), snap.attempt == attempt,
        snap.state == .inFlight || snap.state == .retryScheduled
      else { return }
      try? await d.store.updateRequest(requestID) { p in
        p.taskIdentifier = .some(taskIdentifier)
        if began && snap.state == .retryScheduled { p.state = .inFlight }
      }
    }
  }

  /// Re-processes a persisted response whose completion marker was recorded prior to process termination.
  /// Execution is serialized via `exclusive(_:_:)` to handle race conditions with concurrent transport completions.
  @discardableResult
  func reparse(_ requestID: UUID, attempt: Int) async -> ReparseOutcome {
    await exclusive(requestID) {
      guard let snap = try? await d.store.requestSnapshot(requestID), snap.attempt == attempt, snap.state.isLive else {
        return .alreadyHandled
      }
      let marker = d.files.completeMarkerURL(requestID, attempt: attempt)
      guard FileManager.default.fileExists(atPath: marker.path) else { return .alreadyHandled }
      guard let status = ResponseAccumulator.markerStatus(marker) else {
        // Transport error without an HTTP response; mark interrupted.
        _ = await interrupt(snap, reason: "\(Reconciler.closedReason) (the connection ended without a response)")
        return .interrupted
      }
      // Synthesize transport completion parameters from stored response artifacts.
      let part = d.files.partURL(requestID, attempt: attempt)
      let completion = TransportCompletion(
        requestID: requestID, attempt: attempt, taskIdentifier: -1, httpStatus: status, headers: [:], partURL: part,
        bytesReceived: Self.fileSize(part), error: nil, cancelReason: nil, elapsed: .zero)
      await handleCompleted(completion, reparse: true)
      return .reparsed
    }
  }

  /// Outcome of reevaluating persisted response artifacts during startup reconciliation.
  enum ReparseOutcome: Sendable, Equatable {
    /// Saved response was successfully parsed and applied to the conversation.
    case reparsed
    /// Attempt terminated without response data and transitioned to interrupted.
    case interrupted
    /// Operation bypassed; request state was already finalized or superceded.
    case alreadyHandled
  }

  /// Serializes asynchronous operations on a per-request basis. While Swift actors serialize synchronous execution,
  /// actor reentrancy permits concurrent tasks across suspension points. This mechanism enforces strict FIFO execution
  /// ordering for mutations targeting a specific request ID, ensuring state queries and updates remain synchronized.
  private func exclusive<T>(_ id: UUID, _ body: () async throws -> T) async rethrows -> T {
    if requestLocks[id] == nil {
      requestLocks[id] = []
    } else {
      // Suspend until prior operations on this request complete. Continuation registration occurs synchronously on the actor.
      await withCheckedContinuation { requestLocks[id, default: []].append($0) }
    }
    // Resume subsequent waiter on scope exit, preserving key existence to prevent queue overtaking.
    defer {
      if var waiters = requestLocks[id], !waiters.isEmpty {
        waiters.removeFirst().resume()
        requestLocks[id] = waiters
      } else {
        requestLocks[id] = nil
      }
    }
    return try await body()
  }

  /// Acquires a background task assertion, records the request entity, serializes the request payload,
  /// initiates the initial network attempt, and releases the execution assertion.
  ///
  /// Sustains application execution until the background upload task is handed off to URLSession.
  /// Execution is scoped to an isolated cancellable task responsive to expiration handlers and user cancellation.
  /// Exactly one paired Result log entry is recorded for the request action across all execution outcomes.
  private func prepareWithAssertion(
    action: ActionID, conversation: UUID, claim: UUID, started: ContinuousClock.Instant, reuseRecorded: Bool,
    rebuildBody: Bool = true, categories: [HarmCategory]? = nil, create: @escaping @Sendable () async throws -> UUID
  ) async throws -> UUID {
    let prep = Preparation()
    // A local copy: the handler below runs on the main thread, so it captures only `Sendable` values
    // (the log, the preparation, the action ID) and never the actor's state.
    let log = d.log
    let token = await d.backgroundTasks.begin(name: "gen-prepare") {
      // Once the task has started (or the work finished) the request no longer needs the assertion.
      guard prep.claimExpiry() else { return }
      prep.cancel()
      log.result(action, .interrupted, "background time ran out before the request was sent")
    }

    // Capture the created request ID across task boundaries within a thread safe box.
    let recorded = Locked<UUID?>(nil)
    // Spawn an asynchronous execution task inheriting actor context to perform request staging and launch.
    let work = Task<Void, any Error> {
      let id = try await create()
      recorded.withLock { $0 = id }
      self.register(id, action: action, conversation: conversation, claim: claim, started: started, preparation: prep)
      try Task.checkCancellation()
      try await self.prepareAndStart(
        id, action: action, reuseRecorded: reuseRecorded, rebuildBody: rebuildBody, categories: categories)
    }
    // Bind the active task to preparation tracking.
    // Immediately propagate cancellation if background expiration occurred concurrently.
    prep.task.withLock { $0 = work }
    if prep.expired { work.cancel() }
    let result = await work.result
    let ownsResult = prep.claimFinish()
    let requestID = recorded.value
    if let id = requestID { preparations[id] = nil }
    await d.backgroundTasks.end(token)

    switch result {
    case .success:
      // A successful initialization always registers the request ID before returning.
      return requestID!
    case .failure(let error):
      guard let id = requestID else {
        // Initialization failed prior to persistent record creation (validation error or missing input assets).
        if ownsResult {
          d.log.result(action, .failed, "\(Self.describeError(error))")
        }
        throw (error as? PrepareError) == .inputMissing ? GenerationError.inputMissing : error
      }
      if !ownsResult {
        // Background runtime expired.
        // Log result and purge transient filesystem artifacts.
        try? FileManager.default.removeItem(at: d.files.bodyURL(id))
        try? await d.store.updateRequest(id) { p in
          p.state = .interrupted
          p.completedAt = self.d.clock()
        }
        forget(id)
        throw GenerationError.interrupted
      }
      // Process cancellation initiated by user interaction or task abort signal.
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

  /// Initializes transient runtime tracking for a newly persisted request. Invoked synchronously on the actor.
  private func register(
    _ id: UUID, action: ActionID, conversation: UUID, claim: UUID, started: ContinuousClock.Instant,
    preparation: Preparation
  ) {
    actions[id] = action
    conversationOf[id] = conversation
    startedAt[id] = started
    preparations[id] = preparation
    // Relinquish transient in-memory claim once persistent record state governs conversation concurrency.
    release(conversation, claim)
  }

  /// Serializes request body payload generation (when necessary) and submits the subsequent attempt to transport.
  /// Invoked during initial dispatch, automatic retry scheduling, or category fallback regeneration.
  private func prepareAndStart(
    _ id: UUID, action: ActionID, reuseRecorded: Bool, rebuildBody: Bool, categories: [HarmCategory]?,
    earliestBegin: Date? = nil
  ) async throws {
    guard let snap = try await d.store.requestSnapshot(id) else { throw GenerationError.requestNotFound }
    guard let key = try? d.keyStore.read(), !key.isEmpty else { throw PrepareError.noAPIKey }
    let bodyURL = d.files.bodyURL(id)
    var size = Self.fileSize(bodyURL)
    // Regenerate request payload if body is missing, empty, or safety categories were altered.
    if rebuildBody || size == 0 || categories != nil {
      // Attachment payloads staged at submission time are reused directly.
      let body = try await preparer.prepare(
        snap, parent: action, reuseRecorded: reuseRecorded || snap.selectionReason == .attachments, categories: categories)
      size = body.size
    }
    // Abort if cancellation or background expiration interrupted preparation.
    try Task.checkCancellation()
    // Refresh request snapshot to incorporate prepared input asset references and handle concurrent state changes.
    let fresh = try await d.store.requestSnapshot(id) ?? snap
    // Track tasks initialized during background execution to facilitate foreground promotion upon activation.
    try await startAttempt(
      fresh, action: action, attempt: fresh.attempt + 1, bodyURL: bodyURL, bodySize: size, earliestBegin: earliestBegin,
      apiKey: key, createdInBackground: earliestBegin != nil && !d.activity.isActive)
  }

  /// Commits attempt metadata to persistent storage, initializes telemetry attempt tracking, and delegates execution to transport.
  /// Persistence precedes task activation to prevent racing completions from encountering uninitialized attempt state.
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
    // Verify cancellation status immediately prior to synchronous task initiation.
    if userCancelled.contains(snap.id) {
      attemptActions[snap.id] = nil
      d.log.result(attemptAction, .cancelled, "stopped by the user before the task started")
      throw CancellationError()
    }
    // Enforce background execution assertion constraints for initial attempts.
    if let prep = preparations[snap.id], !prep.claimSending() {
      attemptActions[snap.id] = nil
      d.log.result(attemptAction, .cancelled, "background time ran out before the task started")
      throw CancellationError()
    }
    let taskID: Int
    do {
      taskID = try d.transport.start(job, apiKey: apiKey)
    } catch {
      attemptActions[snap.id] = nil
      d.log.result(attemptAction, .failed, "couldn't create the task: \(error.localizedDescription)")
      throw error
    }
    d.log.step(attemptAction, "upload task \(taskID) \(earliestBegin == nil ? "resumed" : "scheduled")")
    // Record transport task identifier while avoiding state overwrites in case of immediate completion.
    try? await d.store.updateRequest(snap.id) { $0.taskIdentifier = .some(taskID) }
  }

  /// Processes transport lifecycle events sequentially via the background event consumer.
  private func handle(_ event: TransportEvent) async {
    switch event {
    case .began(let requestID, let attempt, let taskIdentifier):
      // Transition scheduled retry task to active flight once URLSession begins transmission.
      await exclusive(requestID) {
        guard let snap = try? await d.store.requestSnapshot(requestID), snap.attempt == attempt,
          snap.state == .retryScheduled
        else { return }
        try? await d.store.updateRequest(requestID) { p in
          p.state = .inFlight
          p.startedAt = self.d.clock()
          p.taskIdentifier = .some(taskIdentifier)
        }
        if let att = attemptActions[requestID] { d.log.step(att, "task \(taskIdentifier) began") }
      }
    case .completed(let completion):
      // Process payload evaluation and persistence within the per-request serialization turn.
      if !d.activity.isActive { completionsSinceFinished += 1 }
      await exclusive(completion.requestID) { await handleCompleted(completion, reparse: false) }
    case .finishedEvents(let id):
      // Await persistence of all pending completions prior to invoking the system background session completion handler.
      let handled = completionsSinceFinished
      completionsSinceFinished = 0
      await d.onBackgroundEventsFinished(id, handled)
    }
  }

  /// Processes attempt completion within the request serialization turn.
  /// Determines whether to discard, abort, schedule auto-retry, perform CIVIC fallback rebuilding, or decode payload.
  private func handleCompleted(_ c: TransportCompletion, reparse: Bool) async {
    let id = c.requestID
    // Preserve response artifacts on storage error to permit startup reconciliation to reprocess.
    let found: RequestSnapshot?
    do { found = try await d.store.requestSnapshot(id) } catch { return }
    guard let snap = found else {
      // Parent chat or request record was deleted.
      // Purge transient files and close telemetry.
      try? FileManager.default.removeItem(at: d.files.requestDir(id))
      if let att = attemptActions.removeValue(forKey: id) {
        d.log.result(att, .cancelled, "the request was deleted")
      } else if let action = actions[id] {
        // Close orphaned attempt activity restored from prior session.
        d.log.result(ofOpenChild: "Attempt \(c.attempt)", of: action, .cancelled, "the request was deleted")
      }
      if let action = actions[id] { d.log.result(action, .cancelled, "the request was deleted") }
      forget(id)
      return
    }
    // Discard events originating from superseded attempts.
    guard c.attempt == snap.attempt else { return }
    // Ignore events if request is actively undergoing local preparation or has reached terminal state,
    // with the exception of late completions arriving after launch interruption.
    guard (snap.state.isLive && snap.state != .preparing) || snap.state == .interrupted else { return }

    // Associate late completions with a dedicated child activity linked to the original action.
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
      // Adopt recorded activity ID if processing first event following process relaunch.
      if actions[id] == nil {
        actions[id] = action
        d.log.step(action, reparse ? "relaunched; re-parsing the saved response" : "relaunched; continuing with attempt \(c.attempt)")
      }
    }

    // Close the attempt.
    let (attemptOutcome, attemptSummary) = Self.describeAttempt(c, userCancelled: userCancelled.contains(id))
    // Conclude prior attempt activities during reparse passes to maintain diagnostic hierarchy.
    if !isLate { closeAttempt(snap, action: action, outcome: attemptOutcome, attemptSummary) }
    if !d.activity.isActive && !reparse { d.log.step(action, "delivered while the app was in the background") }

    // Differentiate between user directed cancellation and system initiated aborts.
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

    // Inspect HTTP error payloads for structured `RetryInfo` attributes and safety policy diagnostics.
    let errorBody: GeminiErrorBody? =
      c.httpStatus.map { !(200..<300).contains($0) } == true ? (try? Data(contentsOf: c.partURL)).flatMap(GeminiErrorBody.decode) : nil
    let result: AttemptResult =
      c.error.map { .transport($0, elapsed: c.elapsed) }
      ?? .http(status: c.httpStatus ?? 0, headers: c.headers, bodyBytes: c.bytesReceived, error: errorBody)
    // Late completions bypass retry evaluation and proceed directly to terminal handling.
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
      // Record fallback activation on the request record and configure default policy to omit the category on subsequent requests.
      try? await d.store.updateRequest(id) { $0.civicFallbackUsed = true }
      await d.setOmitCivicOnMain()
      do {
        try await prepareAndStart(id, action: action, reuseRecorded: true, rebuildBody: true, categories: four)
      } catch {
        await finishAfterStartError(id, error)
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

  /// Schedules a subsequent retry attempt backed by the persisted request body payload.
  /// Operates within the active background execution allowance granted by the transport delegate callback.
  private func scheduleAutoRetry(_ snap: RequestSnapshot, action: ActionID, delay: Duration) async {
    let begin = d.clock().addingTimeInterval(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
    // Update retry counter prior to task scheduling to maintain accurate accounting across crashes.
    try? await d.store.updateRequest(snap.id) { $0.autoRetriesUsed = snap.autoRetriesUsed + 1 }
    do {
      try await prepareAndStart(
        snap.id, action: action, reuseRecorded: true, rebuildBody: false, categories: nil, earliestBegin: begin)
    } catch {
      await finishAfterStartError(snap.id, error)
    }
  }

  /// Finalizes request lifecycle when initialization of an attempt fails or is aborted.
  private func finishAfterStartError(_ id: UUID, _ error: any Error, context: String? = nil) async {
    if userCancelled.contains(id) || error is CancellationError {
      try? await d.store.updateRequest(id) { p in
        p.state = .cancelled
        p.completedAt = self.d.clock()
      }
      await finish(id, outcome: .cancelled, summary: "stopped by the user\(durationSuffix(id))", notify: false)
      return
    }
    let prepError = error as? PrepareError
    let message = prepError?.message ?? (context.map { "\($0): \(error.localizedDescription)" } ?? Self.describeError(error))
    await finishFailed(id, status: prepError?.status ?? .network, message: message)
  }

  /// Decodes the staged response payload, relocates generated image files into permanent conversation storage,
  /// updates message history, and finalizes the request. Payload parsing executes asynchronously off the actor.
  private func parse(_ c: TransportCompletion, snap: RequestSnapshot, action: ActionID) async {
    let id = snap.id
    let status = c.httpStatus ?? 200
    // Record parsing state to inform UI activity indicators and direct startup crash recovery.
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
      // Accumulate successfully relocated image paths to enable cleanup if downstream persistence fails.
      var moved: [URL] = []
      do {
        let (messageParts, images) = try moveImages(parts, conversation: snap.conversationID, moved: &moved)
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
        // Atomically commit reply parts, image records, and terminal outcome metadata.
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
        if !(await recordExists(id)) {
          // Request or parent chat was deleted concurrently during decoding. Discard relocated files.
          for url in moved {
            try? FileManager.default.removeItem(at: url)
          }
          d.log.result(parseAction, .cancelled, "\(took) · the request was deleted")
          await finish(id, outcome: .cancelled, summary: "the request was deleted")
          return
        }
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
      // Log structured error messages, truncating arbitrary binary or raw text responses to 2 KB.
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

  /// Relocates parsed image assets into permanent conversation storage and constructs model output structures.
  private func moveImages(_ parts: [OutputPart], conversation: UUID, moved: inout [URL]) throws -> ([MessagePart], [ReplyImage]) {
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
        moved.append(d.files.url(relative: relative))
        images.append(
          ReplyImage(
            id: imageID, relativePath: relative, mimeType: img.mimeType, byteCount: img.byteCount, pixelWidth: img.pixelWidth,
            pixelHeight: img.pixelHeight))
        messageParts.append(MessagePart(kind: .image, text: nil, imageID: imageID))
      }
    }
    return (messageParts, images)
  }

  /// Asynchronously generates list and bubble thumbnail representations to optimize presentation latency.
  private func warmThumbnails(_ images: [ReplyImage]) {
    guard let thumbnails = d.thumbnails, !images.isEmpty else { return }
    let files = d.files
    // Perform thumbnail generation within an unmanaged detached task to avoid actor execution delays.
    Task.detached(priority: .utility) {
      for image in images {
        for px in [ThumbnailService.listSize, ThumbnailService.bubbleSize] {
          _ = await thumbnails.thumbnail(for: files.url(relative: image.relativePath), id: image.id, px: px)
        }
      }
    }
  }

  /// Commits failure diagnostic information and transitions the request to terminal state.
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

  /// Emits user notifications (if permitted), records the terminal activity outcome, and purges transient runtime state.
  private func finish(
    _ id: UUID, outcome: ActivityOutcome, summary: ActivityMessage, body: String? = nil, notify: Bool = true
  ) async {
    var outcome = outcome
    var summary = summary
    var notify = notify
    // Handle concurrent removal of the request record during asynchronous processing.
    if !(await recordExists(id)) {
      (outcome, summary, notify) = (.cancelled, "the request was deleted", false)
      try? FileManager.default.removeItem(at: d.files.requestDir(id))
    }
    let conversation: UUID? = await conversationID(of: id)
    // Direct diagnostic result to late completion activity if processing an interrupted request.
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
    forget(id)
  }

  /// Verifies existence of the persistent request record. Returns true if storage queries fail.
  private func recordExists(_ id: UUID) async -> Bool {
    do { return try await d.store.requestSnapshot(id) != nil } catch { return true }
  }

  /// Clears in-memory lifecycle state for a concluded request.
  private func forget(_ id: UUID) {
    userCancelled.remove(id)
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

  /// Claims conversation concurrency for a new request prior to database persistence, returning a reservation token.
  private func claim(_ conv: UUID) async throws -> UUID {
    if busyConversations[conv] != nil { throw GenerationError.chatBusy }
    let token = UUID()
    busyConversations[conv] = token
    if (try? await d.store.hasLiveRequest(conv: conv)) == true {
      release(conv, token)
      throw GenerationError.chatBusy
    }
    return token
  }

  /// Releases the conversation reservation token if still held by the caller.
  private func release(_ conv: UUID, _ token: UUID) {
    if busyConversations[conv] == token { busyConversations[conv] = nil }
  }

  /// Resolves the diagnostic activity tracking ID for a request snapshot.
  private func actionFor(_ snap: RequestSnapshot) -> ActionID {
    actions[snap.id] ?? snap.activityActionID ?? ActionID(raw: "0000")
  }

  /// Closes the active attempt activity hierarchy for a given request snapshot.
  private func closeAttempt(_ snap: RequestSnapshot, action: ActionID, outcome: ActivityOutcome, _ summary: ActivityMessage) {
    if let att = attemptActions.removeValue(forKey: snap.id) {
      d.log.result(att, outcome, summary)
    } else if snap.attempt > 0 {
      d.log.result(ofOpenChild: "Attempt \(snap.attempt)", of: action, outcome, summary)
    }
  }

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
