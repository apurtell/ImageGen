import Foundation

/// The UI's only way into generation (M5's `ChatScreenModel` depends on this protocol alone).
/// `Sendable` lets main-actor screen models hold the service and call it; every method is `async`,
/// because each call waits for its turn on the `GenerationService` actor. Tests supply a fake.
protocol GenerationServicing: Sendable {
  func send(_ d: SendDraft) async throws -> UUID
  func regenerate(sourceRequestID: UUID) async throws -> UUID
  func retry(requestID: UUID) async throws
  func cancel(requestID: UUID) async
}

/// The errors that `send`, `regenerate` and `retry` throw to the screen. The request record holds the
/// full outcome; these cases only tell the screen what to show at once.
enum GenerationError: Error, Equatable {
  /// One request in flight per chat (D§4.6).
  case chatBusy
  /// The record is gone, for example because the user deleted its chat.
  case requestNotFound
  /// A Retry of a request that isn't in a retryable state. The case carries the state found (an enum
  /// case with an associated value; see the primer, *Types and values*).
  case notRetryable(RequestState)
  /// A Regenerate whose source input is gone.
  case inputMissing
  /// Preparation failed; the request record holds the details.
  case preparationFailed(LocalErrorStatus)
  /// The background-task assertion expired before the task started.
  case interrupted
  /// The user stopped the request before its task started.
  case cancelled
}

/// The single owner of request state transitions (D§4.6, D§6). It consumes the transport's
/// ordered event stream in one task, handling each event to the end before taking the next, and
/// logs each request as one action (Send, Regenerate or Retry) with Prepare request, Attempt and
/// Parse sub-actions (D§4.13).
///
/// Place in the design: this is the Generation layer's core. The screens (`ChatScreenModel`,
/// `ChatActions`, Settings) call it through `GenerationServicing`. `AppEnvironment` calls
/// `appBecameActive`, and the `Reconciler` calls the hooks under "Reconciler hooks". The service calls
/// `DataStore`, `RequestPreparer`, the transport, `ResponseParser`, `RetryPolicy`, the notifier and the
/// background-task provider. `AppEnvironment` builds exactly one instance.
///
/// Concurrency model. `GenerationService` is an `actor`: it runs one call at a time, but only between
/// suspension points. At each `await` (a store call, a log flush, a parse) the actor can start another
/// call, and that call can change the actor's properties and the stored record. See the primer, *Actors*.
/// So these callers interleave freely: the user's send, regenerate, retry and cancel; the transport's
/// events; the Reconciler's hooks; and the foreground re-creation pass. The compiler prevents data races
/// on the properties, but not these logical races. Each mechanism below prevents one interleaving:
/// - `exclusive(_:_:)` gives each request one handler at a time. A handler reads the record, awaits, then
///   writes. Without the turn, a late completion and a Retry could both act on the same old reading.
/// - A claim (`claim`, `release`, `busyConversations`) keeps a chat to one new request. It covers the gap
///   between the tap and the record's creation. Its token makes sure that a call releases only its own
///   claim, never the claim of a later send.
/// - The Stop record (`userCancelled`) holds a Stop that arrives when no task exists: during preparation,
///   between attempts, or during a rebuild. `startAttempt` checks it just before it creates a task.
/// - A `Preparation` phase decides who writes the Result when the background-task assertion expires.
///   The expiry handler runs on the main thread, outside the actor, so the phase is under a lock.
/// - Attempt numbers: each task and each of its events carries its attempt number. A handler acts on an
///   event only for the record's current attempt, so a replaced or cancelled task changes nothing.
/// - One consumer task awaits each transport event to the end. So `.finishedEvents` is handled only
///   after every earlier completion is saved, and the system completion handler is called only then.
///
/// Store writes that use `try?` here are best effort. A failed write leaves the record in its last
/// state, and the next launch's `Reconciler` repairs a record that stays live (D§4.7).
actor GenerationService: GenerationServicing {
  /// Everything the service uses, passed in so that tests can supply fakes, clocks and gates (see the
  /// primer, *Seams for tests*). The closures are `@Sendable`, so that the struct can pass from
  /// `AppEnvironment` into the actor (see the primer, *Sendable*).
  struct Dependencies: Sendable {
    var transport: any GenerationTransport
    var store: DataStore
    var files: FileStore
    var keyStore: any APIKeyStore
    var log: ActivityLog
    var backgroundTasks: any BackgroundTaskProviding
    var notifier: any NotificationPosting
    var activity: AppActivity
    /// Warms the thumbnails of saved reply images; nil in tests that don't need it.
    var thumbnails: ThumbnailService?
    var retryPolicy = RetryPolicy()
    /// The current Settings defaults, read without the main actor.
    var defaults: @Sendable () -> GenerationDefaults
    /// Sets `AppSettings.omitCivicIntegrity` on the main actor (the actor never writes defaults).
    var setOmitCivicOnMain: @Sendable () async -> Void
    /// Calls the system's completion handler for a background-session wake (through
    /// `BackgroundEventsRelay`). The service calls it only after every earlier completion is saved.
    var onBackgroundEventsFinished: @Sendable (_ sessionID: String, _ completionsHandled: Int) async -> Void
    /// For the Attempt Begin: "background session" or "ephemeral session".
    var sessionDescription = "background session"
    var shrink: @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor
    var budget = BudgetPlanner.budget
    var clock: @Sendable () -> Date = { Date() }
  }

  /// A cancellable preparation. Its phase decides, atomically, who writes the request action's
  /// result when the background-task assertion expires: the expiry handler (nothing sent yet) or
  /// the preparation itself (finished, or the task already started).
  ///
  /// Two parties share this object: the actor, and the expiry handler, which UIKit calls on the main
  /// thread. The handler is synchronous and can't `await` the actor, so the state is in `Locked`
  /// (a `Mutex`; see the primer, *Locks*). That is why the class can be `Sendable`. The phases:
  /// `preparing` becomes `sending` (just before the first task starts), `finished` (the work ended),
  /// or `expired` (the handler won). Each claim below is one step under the lock, so exactly one of
  /// the two parties owns the Result.
  final class Preparation: Sendable {
    enum Phase: Sendable { case preparing, sending, finished, expired }
    let phase = Locked(Phase.preparing)
    /// The work task, stored after it is created, so that the expiry handler and a Stop can cancel it.
    let task = Locked<Task<Void, any Error>?>(nil)

    var expired: Bool { phase.value == .expired }
    /// Cancellation is cooperative: this sets a flag that the work checks between its steps (see the
    /// primer, *Tasks and cancellation*).
    func cancel() { task.value?.cancel() }

    /// The expiry handler: true when it owns the result (nothing sent, the work not finished).
    func claimExpiry() -> Bool {
      phase.withLock { p in
        guard p == .preparing else { return false }
        p = .expired
        return true
      }
    }

    /// Just before the task starts: false when the assertion already expired. It stays true once the
    /// phase is `sending`, so an auto-retry that starts before `prepareWithAssertion` drops the
    /// preparation also passes.
    func claimSending() -> Bool {
      phase.withLock { p in
        if p == .preparing { p = .sending }
        return p == .sending
      }
    }

    /// When the work ends: false when the expiry handler already wrote the result.
    func claimFinish() -> Bool {
      phase.withLock { p in
        guard p != .expired else { return false }
        p = .finished
        return true
      }
    }
  }

  /// Holds the event consumer task. It is a `let` of a `Sendable` class, so the `nonisolated` `stop()`
  /// can reach it without waiting for the actor.
  private final class ConsumerBox: Sendable {
    let task = Locked<Task<Void, Never>?>(nil)
  }

  private let d: Dependencies
  private let preparer: RequestPreparer
  private let consumer = ConsumerBox()

  // The properties below are the actor's in-memory state. Only the actor reads or writes them, but a
  // value read before an `await` can be different after it. The record in `DataStore` is the source
  // of truth; this state only covers the current process and is rebuilt (adopted) after a relaunch.

  /// Chats with a send between the tap and the request record's creation, each with the token of
  /// the call that claimed it: only that call releases it.
  private var busyConversations: [UUID: UUID] = [:]
  /// requestID → its chat, for the notification; `conversationID(of:)` falls back to the store.
  private var conversationOf: [UUID: UUID] = [:]
  /// requestID → the action following it in this process (begun here or adopted).
  private var actions: [UUID: ActionID] = [:]
  /// requestID → a Late completion action.
  private var lateActions: [UUID: ActionID] = [:]
  /// requestID → its open Attempt sub-action.
  private var attemptActions: [UUID: ActionID] = [:]
  /// requestID → when the user's action began in this process, for the durations in the log.
  private var startedAt: [UUID: ContinuousClock.Instant] = [:]
  /// Requests the user stopped. Checked just before a task is created, so a Stop that arrives
  /// while no task exists (preparing, between attempts, rebuilding) still holds.
  private var userCancelled: Set<UUID> = []
  /// requestID → its preparation, while `prepareWithAssertion` runs for it. Its presence also tells
  /// `markInterrupted` that this process is preparing the request, so the request isn't an orphan.
  private var preparations: [UUID: Preparation] = [:]
  /// Completions handled while the app was not active, since the last `.finishedEvents` or the last
  /// time the app became active; reported with that event for the log. Completions handled in the
  /// foreground are not part of any background wake, so they are not counted.
  private var completionsSinceFinished = 0
  /// One handler at a time per request (see `exclusive`): requestID → callers waiting their turn.
  /// A key that is present means a handler has the turn; its array holds the callers that wait.
  private var requestLocks: [UUID: [CheckedContinuation<Void, Never>]] = [:]
  /// The latest foreground re-creation pass; each pass waits for the one before it.
  private var reactivation: Task<Void, Never>?

  init(_ dependencies: Dependencies) {
    d = dependencies
    preparer = RequestPreparer(
      files: dependencies.files, store: dependencies.store, log: dependencies.log, defaults: dependencies.defaults,
      shrink: dependencies.shrink, budget: dependencies.budget)
    // The consumer starts here, as the service is built, so that it reads completions that the system
    // delivers on a background relaunch. The stream buffers events until then (D§4.6).
    let events = dependencies.transport.events
    consumer.task.withLock {
      // `Task {}` starts an unstructured task that runs on its own (see the primer, *Tasks and
      // cancellation*). `[weak self]` keeps the task from holding the service alive; when the service
      // is gone, `guard let self` ends the loop. `for await` takes one event at a time, in order, and
      // the loop awaits `handle` to the end before it takes the next event.
      $0 = Task { [weak self] in
        for await event in events {
          guard let self else { return }
          await self.handle(event)
        }
      }
    }
  }

  /// Stops consuming events (tests that simulate a relaunch). `nonisolated`: it touches no actor
  /// state, so callers don't `await` it.
  nonisolated func stop() {
    consumer.task.value?.cancel()
  }

  // MARK: Send, Regenerate, Retry, Cancel

  // Send, Regenerate and Retry share one shape: claim the chat, begin the user's action, then
  // `prepareWithAssertion`, whose `create` closure makes or resets the record. Each returns when the
  // first task exists (or the preparation failed), not when the reply arrives.

  /// Records a new request from the composer and starts its first attempt. Throws `chatBusy` when
  /// the chat already has a live request or another send is starting.
  func send(_ draft: SendDraft) async throws -> UUID {
    let conv = draft.conversationID
    let claim = try await claim(conv)
    // `defer` runs on every exit (see the primer, *Errors and early exits*). Usually `register`
    // has released the claim already; then this release is a no-op, because of the token.
    defer { release(conv, claim) }

    // The input choice reads the chat as it is now; the claim keeps other sends out meanwhile.
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
    return try await prepareWithAssertion(
      action: action, conversation: conv, claim: claim, started: started, reuseRecorded: false
    ) {
      // One `DataStore` call moves the staged files and creates the records in one step (see the
      // primer, *SwiftData*).
      let record = try await self.d.store.createSend(input)
      return record.requestID
    }
  }

  /// Records a new request that repeats a source request with its recorded inputs and settings.
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
    // Settings now omit CIVIC_INTEGRITY (an earlier CIVIC fallback set it), but the source sent it:
    // rebuild with four categories, so the copy doesn't get the same HTTP 400.
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

  /// Sends a finished request again, as the same record, with its auto-retry budget reset (D§6).
  func retry(requestID: UUID) async throws {
    guard let snap = try await d.store.requestSnapshot(requestID) else { throw GenerationError.requestNotFound }
    // An early check for a fast answer. The state can change before the turn, so `beginRetry`
    // checks it again.
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
    // Reuse `body.json` when it is still there; rebuild it when it is gone (the Janitor or a failed
    // preparation removed it).
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
      // `.some(nil)` clears an optional field; plain nil leaves it unchanged (see `RequestPatch`).
      // The record now follows the Retry action, so a relaunch adopts that action.
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

  /// Stops a request wherever it is: its preparation, its task, or the gap between the two (the
  /// next task is never created). A record already deleted (Delete chat found it live a moment
  /// later) is stopped without a Cancel action of its own; the deleting action logged it.
  ///
  /// This doesn't take the request's turn, and it writes no record state. A Stop must not wait
  /// behind a long handler, for example a parse. The code that ends the request writes `cancelled`:
  /// the completion of the cancelled task, the failed preparation, or `finishAfterStartError`.
  /// A Stop that arrives while the reply is being parsed has no effect; the parse saves its result.
  func cancel(requestID: UUID) async {
    let snap: RequestSnapshot?
    do { snap = try await d.store.requestSnapshot(requestID) } catch { return }
    if let snap, !snap.state.isLive { return }
    let action = snap.map {
      d.log.begin("Cancel", origin: .user, "req \(Format.short(requestID)) · state \($0.state.rawValue)")
    }
    // Record the intent first, before any `await`. From here on, every `startAttempt` sees it, and a
    // completion with `NSURLErrorCancelled` ends as `cancelled` instead of `interrupted` (D§4.6).
    userCancelled.insert(requestID)
    // A request adopted after a relaunch: remember its action (and Attempt) now, so the cancelled
    // completion closes them even if the record is deleted first (Delete chat, message, all).
    if actions[requestID] == nil, let adopted = snap?.activityActionID {
      actions[requestID] = adopted
      conversationOf[requestID] = snap?.conversationID
    }
    let preparing = preparations[requestID]
    preparing?.cancel()
    // Also when preparing: its task may have been created a moment ago.
    await d.transport.cancel(requestID: requestID)
    if let action { d.log.result(action, .success, preparing != nil ? "preparation cancelled" : "task cancelled") }
  }

  /// Re-creates in the foreground every retry task created while the app was inactive, which the
  /// system may treat as discretionary (D§6). Scene activations can come in quick succession
  /// (Control Center, a system alert); each pass waits for the one before it, so a request is
  /// never replaced twice.
  func appBecameActive() async {
    // A wake's count starts after the app was last in the foreground: completions from an earlier
    // background period that had no wake of their own must not be added to a later wake.
    completionsSinceFinished = 0
    // No `await` between reading and writing `reactivation`, so two quick calls can't both chain on
    // the same earlier pass. A `Task {}` made inside the actor runs on the actor too.
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
    // These snapshots can be old by the time each request gets its turn (a `.began` or a completion
    // can come first), so `replaceBackgroundRetry` reads the record again inside the turn.
    for snap in pending where snap.state == .retryScheduled && snap.nextAttemptCreatedInBackground {
      // The key is read from the Keychain for each task created (D§4.6). Without one, the old task stays.
      guard let old = snap.taskIdentifier, let key = try? d.keyStore.read(), !key.isEmpty else { continue }
      await exclusive(snap.id) { await replaceBackgroundRetry(snap.id, oldTask: old, apiKey: key) }
    }
  }

  /// Replaces one background-created retry task, if it is still the one recorded and still waiting
  /// to begin. A task that began, or finished while the app was suspended, keeps its result: its
  /// events may be queued behind this call.
  /// Within the request's turn (`exclusive`).
  private func replaceBackgroundRetry(_ id: UUID, oldTask old: Int, apiKey key: String) async {
    // Same state, same flag, same task: otherwise an earlier pass or an event changed the request.
    guard let snap = try? await d.store.requestSnapshot(id), snap.state == .retryScheduled,
      snap.nextAttemptCreatedInBackground, snap.taskIdentifier == old
    else { return }
    // No bytes sent means the system hasn't begun the task, so nothing is lost by a replacement.
    guard let live = await d.transport.liveTasks().first(where: { $0.taskIdentifier == old }), live.countOfBytesSent == 0
    else { return }
    let action = actionFor(snap)
    // Adopt it, so `finish` closes it if re-creating the task fails.
    actions[id] = action
    conversationOf[id] = snap.conversationID
    // Cancel the old task before the new one exists, so two tasks never run for one request.
    await d.transport.cancel(taskIdentifier: old)
    closeAttempt(snap, action: action, outcome: .cancelled, "replaced: re-created in the foreground")
    d.log.step(action, "background-created retry re-created in the foreground")
    // Keep the original retry delay: the new task begins no earlier than the old one would have.
    let begin = max(d.clock(), snap.nextAttemptAt ?? d.clock())
    do {
      // A new attempt number, so the old task's cancellation (and any event it already queued)
      // fails the attempt check and never touches the new attempt's response file.
      try await startAttempt(
        snap, action: action, attempt: snap.attempt + 1, bodyURL: d.files.bodyURL(id),
        bodySize: Self.fileSize(d.files.bodyURL(id)), earliestBegin: begin, apiKey: key, createdInBackground: false)
    } catch {
      await finishAfterStartError(id, error, context: "couldn't re-create the retry")
    }
  }

  // MARK: Reconciler hooks (D§4.7)

  // The Reconciler lists the records and the live tasks once, at launch, then calls these hooks.
  // By the time a hook runs, a completion may have changed the request. So each hook takes the
  // request's turn, reads the record again, and acts only if the request is still in the state and
  // attempt that the Reconciler saw.

  /// Marks a request interrupted (if it's still live, and still in `expected` when given) and
  /// closes its action; returns that action. A request this process is preparing is left alone.
  /// The grace timer passes `expected`, so a completion that arrived during the grace wins.
  /// `@discardableResult` lets a caller ignore the returned action.
  @discardableResult
  func markInterrupted(_ requestID: UUID, reason: String, expected: (state: RequestState, attempt: Int)? = nil) async
    -> ActionID?
  {
    await exclusive(requestID) {
      // A request this process is preparing is not an orphan: its preparation owns it until the
      // first task starts, and ends it on every failure path.
      guard preparations[requestID] == nil, let snap = try? await d.store.requestSnapshot(requestID), snap.state.isLive
      else { return nil }
      if let expected, snap.state != expected.state || snap.attempt != expected.attempt { return nil }
      return await interrupt(snap, reason: reason)
    }
  }

  /// Within the request's turn. Writes the request action's one Result itself, and forgets the
  /// request. A completion that arrives later is a late completion (see `handleCompleted`).
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

  /// Refreshes a request's live task; a delayed task that has begun moves to `inFlight`. Nothing
  /// changes when the request has moved past that attempt since the Reconciler listed the tasks.
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

  /// Re-parses a response whose `.complete` marker survived a crash (D§4.7 step 4): only for the
  /// attempt the Reconciler checked, and only while it is still that request's live attempt. The
  /// transport may be delivering the same completion right now; the request's turn makes the
  /// second of the two find it finished.
  ///
  /// Returns what it did, so the Reconciler's log says what really happened. `alreadyHandled` means
  /// that something else (usually the transport's own completion) ended the attempt first.
  @discardableResult
  func reparse(_ requestID: UUID, attempt: Int) async -> ReparseOutcome {
    await exclusive(requestID) {
      guard let snap = try? await d.store.requestSnapshot(requestID), snap.attempt == attempt, snap.state.isLive else {
        return .alreadyHandled
      }
      let marker = d.files.completeMarkerURL(requestID, attempt: attempt)
      guard FileManager.default.fileExists(atPath: marker.path) else { return .alreadyHandled }
      guard let status = ResponseAccumulator.markerStatus(marker) else {
        // A transport error ended the attempt (no HTTP status): there is nothing to parse.
        _ = await interrupt(snap, reason: "\(Reconciler.closedReason) (the connection ended without a response)")
        return .interrupted
      }
      // A completion built from the saved files. No task exists in this process, so the task
      // identifier is -1 and the elapsed time is zero.
      let part = d.files.partURL(requestID, attempt: attempt)
      let completion = TransportCompletion(
        requestID: requestID, attempt: attempt, taskIdentifier: -1, httpStatus: status, headers: [:], partURL: part,
        bytesReceived: Self.fileSize(part), error: nil, cancelReason: nil, elapsed: .zero)
      await handleCompleted(completion, reparse: true)
      return .reparsed
    }
  }

  /// What `reparse` did with a saved response.
  enum ReparseOutcome: Sendable, Equatable {
    /// The saved response was parsed and its request ended.
    case reparsed
    /// The attempt ended with a transport error and no response, so the request was interrupted.
    case interrupted
    /// Nothing to do: the request had already ended, moved to another attempt, or lost its marker.
    case alreadyHandled
  }

  // MARK: One handler at a time per request

  /// Runs `body` when no other handler is working on the request: the transport's events, a
  /// re-parse, an interruption, a Retry's first step and a foreground re-creation each read the
  /// request, await, then write it. An actor runs one call at a time but lets another call in at
  /// every `await`, so without this two of them could act on the same stale reading. Waiters go
  /// in arrival order. `body` must not call `exclusive` for the same request (it would wait for
  /// itself).
  ///
  /// The turn covers only the callers that use it. `cancel` doesn't take it, because it writes no
  /// state. The preparation in `prepareWithAssertion` doesn't take it either: until its task starts,
  /// the only events for the request belong to an older attempt, and `handleCompleted` ignores them
  /// (the state is `preparing`, then the attempt number differs). Different requests never wait for
  /// each other. `rethrows`: this throws only when `body` throws. See the primer, *One handler at a
  /// time for each request*.
  private func exclusive<T>(_ id: UUID, _ body: () async throws -> T) async rethrows -> T {
    if requestLocks[id] == nil {
      requestLocks[id] = []
    } else {
      // Wait for the turn. The closure runs at once, on the actor, before the suspension, so no
      // other call can slip in between the check above and the append. The holder that ends its
      // turn resumes this continuation exactly once (see the primer, *Continuations*).
      await withCheckedContinuation { requestLocks[id, default: []].append($0) }
    }
    // On exit, hand the turn straight to the first waiter: the key stays present, so a new caller
    // that arrives now queues behind the waiters instead of overtaking them.
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

  // MARK: Preparation

  /// Takes the background-task assertion, records the request (`create`), prepares the body and
  /// starts the first attempt, then ends the assertion (D§4.6).
  ///
  /// Only the system-owned upload task survives when iOS suspends the app, so the app must stay awake
  /// until the task exists (see the primer, *iOS application lifecycle*). The work runs in its own
  /// task, so that the expiry handler and a Stop can cancel it. Exactly one Result is written for the
  /// request action on each failure path here: by the expiry handler, or by this function (directly or
  /// through `finish`). On success, the request's later handlers write it.
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

    // The work task reports the new record's ID here, so the failure paths below know whether a
    // record exists. A task's closure can't change a local `var`, so the ID goes through a box.
    let recorded = Locked<UUID?>(nil)
    // A `Task {}` made inside the actor runs on the actor, so it calls `register` directly. It is
    // still a separate task: cancelling it doesn't cancel the caller.
    let work = Task<Void, any Error> {
      let id = try await create()
      recorded.withLock { $0 = id }
      self.register(id, action: action, conversation: conversation, claim: claim, started: started, preparation: prep)
      try Task.checkCancellation()
      try await self.prepareAndStart(
        id, action: action, reuseRecorded: reuseRecorded, rebuildBody: rebuildBody, categories: categories)
    }
    // The handler may have fired before the task was stored, when `prep.cancel()` had nothing to
    // cancel. Checking the phase after the store closes that gap.
    prep.task.withLock { $0 = work }
    if prep.expired { work.cancel() }
    let result = await work.result
    let ownsResult = prep.claimFinish()
    let requestID = recorded.value
    if let id = requestID { preparations[id] = nil }
    await d.backgroundTasks.end(token)

    switch result {
    case .success:
      // A success always passed `register`, so the ID is set (`!` would stop the app otherwise).
      return requestID!
    case .failure(let error):
      guard let id = requestID else {
        // Nothing was recorded (createSend failed, or a regenerate input is missing).
        if ownsResult {
          d.log.result(action, .failed, "\(Self.describeError(error))")
        }
        throw (error as? PrepareError) == .inputMissing ? GenerationError.inputMissing : error
      }
      if !ownsResult {
        // The expiry handler already logged the result. Cleanup; the Janitor removes anything left.
        try? FileManager.default.removeItem(at: d.files.bodyURL(id))
        try? await d.store.updateRequest(id) { p in
          p.state = .interrupted
          p.completedAt = self.d.clock()
        }
        forget(id)
        throw GenerationError.interrupted
      }
      // A Stop: either it cancelled the work task, or `startAttempt` found the Stop record.
      if error is CancellationError || userCancelled.contains(id) {
        userCancelled.remove(id)
        // Cleanup; the Janitor removes anything left (D§4.4).
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

  /// Starts the in-memory bookkeeping for a request whose record now exists. Synchronous, so it
  /// runs as one step on the actor.
  private func register(
    _ id: UUID, action: ActionID, conversation: UUID, claim: UUID, started: ContinuousClock.Instant,
    preparation: Preparation
  ) {
    actions[id] = action
    conversationOf[id] = conversation
    startedAt[id] = started
    preparations[id] = preparation
    // From here the request record (live until terminal) keeps the chat to one request; releasing
    // the in-memory claim now means the chat is free the moment the record turns terminal.
    release(conversation, claim)
  }

  /// Writes the body (unless an existing one is reused) and starts the next attempt.
  /// Callers: the first preparation (in its work task), and, inside a completion's turn, an
  /// auto-retry (`earliestBegin` set) or a CIVIC rebuild (`categories` set).
  private func prepareAndStart(
    _ id: UUID, action: ActionID, reuseRecorded: Bool, rebuildBody: Bool, categories: [HarmCategory]?,
    earliestBegin: Date? = nil
  ) async throws {
    guard let snap = try await d.store.requestSnapshot(id) else { throw GenerationError.requestNotFound }
    guard let key = try? d.keyStore.read(), !key.isEmpty else { throw PrepareError.noAPIKey }
    let bodyURL = d.files.bodyURL(id)
    var size = Self.fileSize(bodyURL)
    // A missing or empty body, or new categories, always needs a new body.
    if rebuildBody || size == 0 || categories != nil {
      // Attachments were prepared at send time, so their recorded files are sent as they are.
      let body = try await preparer.prepare(
        snap, parent: action, reuseRecorded: reuseRecorded || snap.selectionReason == .attachments, categories: categories)
      size = body.size
    }
    // Stop here if a Stop or the expiry cancelled the work task during the preparation.
    try Task.checkCancellation()
    // Read the record again: the preparer wrote the inputs it sent, and other calls ran during the awaits.
    let fresh = try await d.store.requestSnapshot(id) ?? snap
    // A retry task created while the app isn't active may be discretionary; `appBecameActive`
    // re-creates it (D§6).
    try await startAttempt(
      fresh, action: action, attempt: fresh.attempt + 1, bodyURL: bodyURL, bodySize: size, earliestBegin: earliestBegin,
      apiKey: key, createdInBackground: earliestBegin != nil && !d.activity.isActive)
  }

  /// Persists the attempt, begins its Attempt sub-action, then starts the task. The state is saved
  /// before the task exists, so a fast completion can't be overwritten afterwards.
  /// The new attempt number goes into the record and into the task, so each later event names the
  /// attempt it belongs to. Every path that throws after the Attempt Begin closes that sub-action.
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
    // From here to `transport.start` nothing awaits, so a Stop either happened before this check or
    // happens after the task exists (and `cancel` finds it).
    if userCancelled.contains(snap.id) {
      attemptActions[snap.id] = nil
      d.log.result(attemptAction, .cancelled, "stopped by the user before the task started")
      throw CancellationError()
    }
    // A first attempt still under its preparation's assertion starts only if that hasn't expired.
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
    // Only the task identifier, never the state: a fast completion may already have ended the
    // request during this `await`'s wait for the store. A lost identifier is harmless; the Reconciler
    // and `.began` refresh it.
    try? await d.store.updateRequest(snap.id) { $0.taskIdentifier = .some(taskID) }
  }

  // MARK: Events

  /// Handles one transport event to the end; only the consumer task calls this, one event at a time.
  /// Other calls (a send, a Stop, a Reconciler hook) can still run at each `await` inside it.
  private func handle(_ event: TransportEvent) async {
    // `case .began(let …)` takes the values that the enum case carries.
    switch event {
    case .began(let requestID, let attempt, let taskIdentifier):
      // A delayed retry task began: `retryScheduled` → `inFlight`, for the current attempt only.
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
      // Parse and save inside the request's turn; the consumer takes the next event only after this.
      if !d.activity.isActive { completionsSinceFinished += 1 }
      await exclusive(completion.requestID) { await handleCompleted(completion, reparse: false) }
    case .finishedEvents(let id):
      // Every earlier completion is saved by now, because the consumer awaited each one. So the
      // system completion handler is called only after the results are on disk (D§4.6).
      let handled = completionsSinceFinished
      completionsSinceFinished = 0
      await d.onBackgroundEventsFinished(id, handled)
    }
  }

  /// Within the request's turn (`exclusive`).
  ///
  /// Decides what one finished attempt means for its request: discard it (record deleted, old
  /// attempt, request already ended), end it (Stop or system cancel), retry it, rebuild it without
  /// CIVIC_INTEGRITY, or parse the response. `reparse` is true when the Reconciler replays a saved
  /// response after a relaunch.
  private func handleCompleted(_ c: TransportCompletion, reparse: Bool) async {
    let id = c.requestID
    // A store error is not a deletion: keep the response and its folder. The record stays live, so
    // the next launch's Reconciler re-parses the saved response (its `.complete` marker exists).
    let found: RequestSnapshot?
    do { found = try await d.store.requestSnapshot(id) } catch { return }
    guard let snap = found else {
      // The record was deleted (with its chat or message): discard the result and its files (best
      // effort; the Janitor removes anything left).
      try? FileManager.default.removeItem(at: d.files.requestDir(id))
      if let att = attemptActions.removeValue(forKey: id) {
        d.log.result(att, .cancelled, "the request was deleted")
      } else if let action = actions[id] {
        // An adopted request's Attempt was begun by an earlier process.
        d.log.result(ofOpenChild: "Attempt \(c.attempt)", of: action, .cancelled, "the request was deleted")
      }
      if let action = actions[id] { d.log.result(action, .cancelled, "the request was deleted") }
      forget(id)
      return
    }
    // An older attempt's event (a replaced or cancelled task): the request has moved on.
    guard c.attempt == snap.attempt else { return }
    // `preparing` has no task: a Retry is rebuilding the request, and this is the completion of
    // an attempt it replaces.
    // Other terminal states already have their outcome. `interrupted` is the exception: a late
    // completion always wins over it (D§4.7).
    guard (snap.state.isLive && snap.state != .preparing) || snap.state == .interrupted else { return }

    // A late completion gets its own action, linked to the original one, which is already closed.
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
      // First event for this request in this process (a relaunch): adopt the recorded action.
      if actions[id] == nil {
        actions[id] = action
        d.log.step(action, reparse ? "relaunched; re-parsing the saved response" : "relaunched; continuing with attempt \(c.attempt)")
      }
    }

    // Close the attempt.
    let (attemptOutcome, attemptSummary) = Self.describeAttempt(c, userCancelled: userCancelled.contains(id))
    // A re-parse closes the earlier process's Attempt with its real outcome (by name), instead of
    // leaving it to the log's "parent finished first" backstop.
    if !isLate { closeAttempt(snap, action: action, outcome: attemptOutcome, attemptSummary) }
    if !d.activity.isActive && !reparse { d.log.step(action, "delivered while the app was in the background") }

    // Who cancelled (D§4.6): the user, if the Stop record has the request; otherwise the system
    // (force quit, background updates off, low resources), which ends it `interrupted` with Retry.
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

    // A non-2xx body may carry `RetryInfo` and the CIVIC hint. An unreadable file means no hint.
    let errorBody: GeminiErrorBody? =
      c.httpStatus.map { !(200..<300).contains($0) } == true ? (try? Data(contentsOf: c.partURL)).flatMap(GeminiErrorBody.decode) : nil
    let result: AttemptResult =
      c.error.map { .transport($0, elapsed: c.elapsed) }
      ?? .http(status: c.httpStatus ?? 0, headers: c.headers, bodyBytes: c.bytesReceived, error: errorBody)
    // A late completion is never retried. The counters come from the record, not from memory.
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
      // Mark the fallback used (at most once per request), and make later sends omit the category.
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

  /// Starts the next attempt as a delayed task from the existing `body.json`. It needs no
  /// background-task assertion: it runs inside the system's background-event window (D§4.6).
  private func scheduleAutoRetry(_ snap: RequestSnapshot, action: ActionID, delay: Duration) async {
    let begin = d.clock().addingTimeInterval(Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
    // Count the retry in the record before the task exists, so the count survives a relaunch.
    try? await d.store.updateRequest(snap.id) { $0.autoRetriesUsed = snap.autoRetriesUsed + 1 }
    do {
      try await prepareAndStart(
        snap.id, action: action, reuseRecorded: true, rebuildBody: false, categories: nil, earliestBegin: begin)
    } catch {
      await finishAfterStartError(snap.id, error)
    }
  }

  /// A later attempt couldn't start: the user stopped it, or preparing or creating it failed.
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

  // MARK: Parsing and saving

  /// Within the request's turn. Parses the saved response, moves the images into the chat and saves
  /// the reply, then calls `finish`. `ResponseParser.parse` runs off the actor (`@concurrent`), so the
  /// actor serves other calls meanwhile; the turn keeps other handlers of this request out.
  private func parse(_ c: TransportCompletion, snap: RequestSnapshot, action: ActionID) async {
    let id = snap.id
    let status = c.httpStatus ?? 200
    // `parsing` drives the pending card, and tells the Reconciler to re-parse after a crash (D§4.7).
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
      // `moveImages` fills `moved` as it goes, so a failure later can remove what was moved.
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
        // One store call saves the reply parts, the images and the outcome in one step.
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
          // Deleted while parsing (with its chat or message): the moved images belong to nothing.
          for url in moved {
            try? FileManager.default.removeItem(at: url)  // Best effort; the Janitor removes anything left.
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
      // A JSON error logs its message; any other body logs its first 2 KB with a note of the cut.
      let raw = (try? Data(contentsOf: c.partURL)) ?? Data()  // Unreadable: log an empty body.
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
  /// `moved` is `inout`: the function changes the caller's array, so the caller still sees every moved
  /// file when a later move throws.
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

  /// Makes the list and bubble thumbnails early, so the new reply draws at once.
  private func warmThumbnails(_ images: [ReplyImage]) {
    guard let thumbnails = d.thumbnails, !images.isEmpty else { return }
    let files = d.files
    // `Task.detached` doesn't run on the actor, so the decoding never delays the next event. Nobody
    // waits for it; a failure only means the thumbnail is made later, when it is drawn.
    Task.detached(priority: .utility) {
      for image in images {
        for px in [ThumbnailService.listSize, ThumbnailService.bubbleSize] {
          _ = await thumbnails.thumbnail(for: files.url(relative: image.relativePath), id: image.id, px: px)
        }
      }
    }
  }

  // MARK: Finishing

  // Exactly one Result is written for each request action. `finish` writes it on most paths.
  // `interrupt` writes it for the Reconciler hooks, and on the expiry path the expiry handler writes
  // it. After the Result, `forget` drops the in-memory state, so no later path finds the action.

  /// Saves a failure outcome and finishes the request.
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

  /// Notifies (unless suppressed) and writes the action's one result. A request deleted meanwhile
  /// (with its chat or message, while this handler awaited) ends cancelled, with no notification.
  private func finish(
    _ id: UUID, outcome: ActivityOutcome, summary: ActivityMessage, body: String? = nil, notify: Bool = true
  ) async {
    var outcome = outcome
    var summary = summary
    var notify = notify
    // The handler awaited before it got here, so the record may be gone (Delete chat or message).
    if !(await recordExists(id)) {
      (outcome, summary, notify) = (.cancelled, "the request was deleted", false)
      try? FileManager.default.removeItem(at: d.files.requestDir(id))  // Best effort; the Janitor removes anything left.
    }
    let conversation: UUID? = await conversationID(of: id)
    // A late completion's Result goes to its own action; the original action is already closed.
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

  /// False only when the store answers that the record is gone (a store error counts as present).
  private func recordExists(_ id: UUID) async -> Bool {
    do { return try await d.store.requestSnapshot(id) != nil } catch { return true }
  }

  /// Drops all in-memory state for a request that has ended. The record keeps the outcome.
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

  /// Claims the chat for one new request until its record exists; returns the claim's token.
  /// Two checks cover the two windows: the in-memory claim covers a send whose record doesn't exist
  /// yet, and `hasLiveRequest` covers a request whose record is live (D§4.6, one per chat).
  private func claim(_ conv: UUID) async throws -> UUID {
    if busyConversations[conv] != nil { throw GenerationError.chatBusy }
    // Take the claim before the `await` below, so a second tap that arrives during it finds the chat busy.
    let token = UUID()
    busyConversations[conv] = token
    if (try? await d.store.hasLiveRequest(conv: conv)) == true {
      release(conv, token)
      throw GenerationError.chatBusy
    }
    return token
  }

  /// Releases the chat only if this token still holds it (a later call may have claimed it since).
  /// Example: `register` releases the claim, and a new send claims the chat. While the new send
  /// awaits `hasLiveRequest`, the first call's `defer` runs. The token check makes that release a
  /// no-op; without it, a third send could claim the chat at the same time as the second.
  private func release(_ conv: UUID, _ token: UUID) {
    if busyConversations[conv] == token { busyConversations[conv] = nil }
  }

  /// The action following a request: this process's, or the one recorded on it (adopted).
  /// "0000" is a placeholder for a record with no action.
  private func actionFor(_ snap: RequestSnapshot) -> ActionID {
    actions[snap.id] ?? snap.activityActionID ?? ActionID(raw: "0000")
  }

  /// Ends the request's open Attempt sub-action: the one begun in this process, or else (after a
  /// relaunch) the open child named for the current attempt, which the log store finds.
  private func closeAttempt(_ snap: RequestSnapshot, action: ActionID, outcome: ActivityOutcome, _ summary: ActivityMessage) {
    if let att = attemptActions.removeValue(forKey: snap.id) {
      d.log.result(att, outcome, summary)
    } else if snap.attempt > 0 {
      d.log.result(ofOpenChild: "Attempt \(snap.attempt)", of: action, outcome, summary)
    }
  }

  // MARK: Descriptions (D§4.13 Messages)

  // The text of the log's Begin, Step and Result messages. The `static` ones read no actor state.

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
