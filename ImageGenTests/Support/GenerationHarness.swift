import CryptoKit
import Foundation
import Testing

@testable import ImageGen

/// Controllable generation transport implementation that logs submitted jobs and yields scripted events on demand.
final class ScriptedTransport: GenerationTransport {
  let events: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation
  private let files: FileStore
  let jobs = Locked<[TransportJob]>([])
  let cancelledRequests = Locked<[UUID]>([])
  let cancelledTasks = Locked<[Int]>([])
  let live = Locked<[LiveTask]>([])
  private let nextID = Locked(100)
  /// When enabled, forces `start` invocations to throw, simulating task creation failures in the underlying session.
  let failStarts = Locked(false)

  struct StartFailed: Error {}

  init(files: FileStore) {
    self.files = files
    (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
  }

  func start(_ job: TransportJob, apiKey: String) throws -> Int {
    if failStarts.value { throw StartFailed() }
    try ResponseAccumulator(files: files).prepareNewAttempt(requestID: job.requestID, attempt: job.attempt)
    jobs.withLock { $0.append(job) }
    let id = nextID.withLock { n in
      n += 1
      return n
    }
    live.withLock { $0.append(LiveTask(requestID: job.requestID, attempt: job.attempt, taskIdentifier: id, countOfBytesSent: 0)) }
    return id
  }

  func cancel(requestID: UUID) async { cancelledRequests.withLock { $0.append(requestID) } }
  func cancel(taskIdentifier: Int) async { cancelledTasks.withLock { $0.append(taskIdentifier) } }
  func liveTasks() async -> [LiveTask] { live.value }

  /// Writes payload bytes to the attempt's partial response file, creates completion markers, and yields a `.completed` transport event.
  func complete(
    _ requestID: UUID, attempt: Int, status: Int? = 200, body: Data = Data(), error: URLError.Code? = nil,
    cancelReason: Int? = nil, elapsed: Duration = .seconds(1), taskIdentifier: Int = 1
  ) {
    // Ensures the request directory structure exists prior to accumulator writes.
    try? FileStore.createDirectory(files.requestDir(requestID))
    live.withLock { $0.removeAll { $0.requestID == requestID && $0.attempt == attempt } }
    let acc = ResponseAccumulator(files: files)
    if !body.isEmpty { acc.append(body, requestID: requestID, attempt: attempt, taskIdentifier: taskIdentifier) }
    let (url, bytes) = acc.complete(requestID: requestID, attempt: attempt, taskIdentifier: taskIdentifier, httpStatus: error == nil ? status : nil)
    continuation.yield(
      .completed(
        TransportCompletion(
          requestID: requestID, attempt: attempt, taskIdentifier: taskIdentifier, httpStatus: error == nil ? status : nil,
          headers: [:], partURL: url, bytesReceived: bytes, error: error, cancelReason: cancelReason, elapsed: elapsed)))
  }

  func yield(_ event: TransportEvent) { continuation.yield(event) }
}

/// Weak reference wrapper preventing retain cycles in harness-owned callbacks.
final class WeakHarness: @unchecked Sendable {
  weak var value: GenerationHarness?
}

/// Deterministic pause coordinator allowing test drivers to manually resume suspended async tasks.
final class ManualSleeper: Sendable {
  private let state = Locked<(requested: [Duration], waiting: [CheckedContinuation<Void, Never>])>(([], []))

  var requested: [Duration] { state.value.requested }
  var waitingCount: Int { state.value.waiting.count }

  func sleep(_ d: Duration) async {
    await withCheckedContinuation { c in
      state.withLock { s in
        s.requested.append(d)
        s.waiting.append(c)
      }
    }
  }

  /// Resumes all pending continuations currently suspended within sleep calls.
  func advance() {
    let waiting = state.withLock { s in
      defer { s.waiting = [] }
      return s.waiting
    }
    for c in waiting { c.resume() }
  }
}

/// Mock background task provider that records lifecycle events, flushes the activity log upon task completion, and supports simulated expiration triggers.
final class RecordingBackgroundTaskProvider: BackgroundTaskProviding {
  enum Event: Equatable {
    case begin(String)
    /// Recorded line count of the backing log file immediately following the completion flush.
    case end(fileLines: Int)
    case expired(fileLines: Int)
  }

  let log: ActivityLog
  let events = Locked<[Event]>([])
  private let expiries = Locked<[Int: @Sendable () -> Void]>([:])
  private let next = Locked(0)

  init(log: ActivityLog) { self.log = log }

  func begin(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundTaskToken {
    let id = next.withLock { n in
      n += 1
      return n
    }
    expiries.withLock { $0[id] = onExpire }
    events.withLock { $0.append(.begin(name)) }
    return BackgroundTaskToken(id: id)
  }

  func end(_ token: BackgroundTaskToken) async {
    guard expiries.withLock({ $0.removeValue(forKey: token.id) }) != nil else { return }
    await log.flush()
    let lines = Self.lineCount(log.fileURL)
    events.withLock { $0.append(.end(fileLines: lines)) }
  }

  /// Simulates OS expiration callbacks across all active background task assertions.
  func fireExpiry() async {
    let handlers = expiries.withLock { e in
      defer { e = [:] }
      return Array(e.values)
    }
    for h in handlers {
      h()
      await log.flush()
      events.withLock { $0.append(.expired(fileLines: Self.lineCount(log.fileURL))) }
    }
  }

  static func lineCount(_ url: URL) -> Int {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
  }
}

/// Comprehensive test harness orchestrating isolated storage, mock transports, activity probes, and service dependencies.
final class GenerationHarness: Sendable {
  static let flashURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent")!

  let s: InMemoryStore
  let probe: ActivityLogProbe
  let token = MockURLProtocol.makeToken()
  let registry = SecretRegistry()
  let keyStore: InMemoryKeyStore
  let tasks: RecordingBackgroundTaskProvider
  let activity: AppActivity
  let notifications = Locked<[ReplyNotification]>([])
  let notifyEnabled = Locked(true)
  let edge = Locked(2048)
  let omitCivic = Locked(false)
  let civicCalls = Locked(0)
  /// Optional synchronization hook invoked during civic fallback processing prior to request body reconstruction.
  let civicGate = Locked<(@Sendable () async -> Void)?>(nil)
  let finishedCalls = Locked<[(id: String, handled: Int, statesAtCall: [RequestState])]>([])
  let jobs = Locked<[TransportJob]>([])
  let sleeper: ManualSleeper?
  let urlTransport: URLSessionTransport?
  let scripted: ScriptedTransport?
  let service: GenerationService
  let clock: TestClock

  init(
    scripted useScripted: Bool = false, manualSleeper: Bool = false, key: String? = "test-key",
    budget: Int = BudgetPlanner.budget,
    shrink: @escaping @Sendable (PreparedImage, Int) async throws -> PreparedImage = BudgetPlanner.shrinkWithPreprocessor,
    sanitize: (@Sendable (SecretRegistry) -> @Sendable (String) -> String)? = nil,
    logLimits: ActivityLogStore.Limits = .standard, active: Bool = false,
    reuse: GenerationHarness? = nil
  ) throws {
    clock = reuse?.clock ?? TestClock(Date())
    if let reused = reuse?.s {
      s = reused
    } else {
      s = try InMemoryStore(clock: clock)
    }
    let registry = self.registry
    let identity: @Sendable (String) -> String = { $0 }
    let sanitizer: @Sendable (String) -> String = sanitize?(registry) ?? identity
    probe = ActivityLogProbe(root: s.root, sanitize: sanitizer, limits: logLimits)
    keyStore = InMemoryKeyStore(key: key, registry: registry)
    tasks = RecordingBackgroundTaskProvider(log: probe.log)
    activity = AppActivity(isActive: active)
    let sleeper: ManualSleeper? = manualSleeper ? ManualSleeper() : nil
    self.sleeper = sleeper
    let token = self.token
    if useScripted {
      let t = ScriptedTransport(files: s.files)
      scripted = t
      urlTransport = nil
    } else {
      scripted = nil
      urlTransport = URLSessionTransport(
        configuration: MockURLProtocol.configuration(), files: s.files,
        sleeper: { d in
          if let sleeper { await sleeper.sleep(d) }
        },
        requestDecorator: { $0.setValue(token, forHTTPHeaderField: MockURLProtocol.tokenHeader) })
    }
    let jobs = self.jobs
    let inner: any GenerationTransport = scripted ?? urlTransport!
    let transport = RecordingTransport(inner: inner, jobs: jobs)
    let edge = self.edge
    let omitCivic = self.omitCivic
    let civicCalls = self.civicCalls
    let civicGate = self.civicGate
    let notifications = self.notifications
    let notifyEnabled = self.notifyEnabled
    let finishedCalls = self.finishedCalls
    let store = s.store
    let clock = self.clock
    let notifier = NotificationPoster(
      activity: activity, isEnabled: { notifyEnabled.value },
      deliver: { (n: ReplyNotification) async -> Void in notifications.withLock { $0.append(n) } })
    let defaults: @Sendable () -> GenerationDefaults = {
      var d = GenerationDefaults()
      d.maxUploadLongEdge = edge.value
      d.omitCivicIntegrity = omitCivic.value
      return d
    }
    let setOmitCivic: @Sendable () async -> Void = {
      civicCalls.withLock { $0 += 1 }
      omitCivic.withLock { $0 = true }
      if let gate = civicGate.value { await gate() }
    }
    let finished: @Sendable (String, Int) async -> Void = { id, handled in
      let states = ((try? await store.nonTerminalRequests()) ?? []).map(\.state)
      finishedCalls.withLock { $0.append((id, handled, states)) }
    }
    let now: @Sendable () -> Date = { clock.now }
    var deps = GenerationService.Dependencies(
      transport: transport, store: s.store, files: s.files, keyStore: keyStore, log: probe.log, backgroundTasks: tasks,
      notifier: notifier, activity: activity, thumbnails: nil, defaults: defaults, setOmitCivicOnMain: setOmitCivic,
      onBackgroundEventsFinished: finished)
    deps.sessionDescription = "ephemeral session"
    deps.shrink = shrink
    deps.budget = budget
    deps.clock = now
    service = GenerationService(deps)
  }

  deinit {
    service.stop()
    urlTransport?.invalidateAndWait()
    MockURLProtocol.reset(token: token)
  }

  var defaults: GenerationDefaults {
    var d = GenerationDefaults()
    d.maxUploadLongEdge = edge.value
    d.omitCivicIntegrity = omitCivic.value
    return d
  }

  static func url(model: String) -> URL {
    URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiEndpoint.pathSegment(model)):generateContent")!
  }

  /// Registers canned fixture responses, inferring HTTP error status codes for fixtures located under `Errors/`.
  func respond(_ fixtures: String..., model: String = ModelCatalog.defaultModelID, delay: Duration = .zero) throws {
    let responses = try fixtures.map { name -> MockURLProtocol.Response in
      let status: Int
      if name.hasPrefix("Errors/err_") {
        status = Int(name.dropFirst("Errors/err_".count).prefix(3)) ?? 500
      } else {
        status = 200
      }
      return MockURLProtocol.Response(status: status, body: try FixtureLoader.data(name), delay: delay)
    }
    MockURLProtocol.register(responses, for: Self.url(model: model), token: token)
  }

  func respond(status: Int, body: Data, headers: [String: String] = [:], model: String = ModelCatalog.defaultModelID, delay: Duration = .zero) {
    MockURLProtocol.register(
      [MockURLProtocol.Response(status: status, headers: headers, body: body, delay: delay)], for: Self.url(model: model),
      token: token)
  }

  var recorded: [MockURLProtocol.RecordedRequest] { MockURLProtocol.recorded(token: token) }

  /// Deserialized JSON payloads captured by the mock protocol across recorded requests.
  var sentBodies: [[String: Any]] {
    recorded.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
  }

  func draft(_ conv: UUID, _ prompt: String, attachments: [StagedAttachment] = [], overrides: ChatOverrides = ChatOverrides())
    -> SendDraft
  {
    SendDraft(
      conversationID: conv, promptText: prompt, attachments: attachments,
      settings: GenerationSettingsResolver.resolve(overrides, defaults))
  }

  func snapshot(_ id: UUID) async throws -> RequestSnapshot {
    try #require(try await s.store.requestSnapshot(id))
  }

  /// Polls the database asynchronously until the specified request transitions into one of the designated target states.
  @discardableResult
  func wait(
    _ id: UUID, for states: Set<RequestState> = Set(RequestState.allCases.filter(\.isTerminal)),
    timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> RequestSnapshot {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let snap = try await s.store.requestSnapshot(id), states.contains(snap.state) {
        // Terminal database states are committed prior to final result logging; wait for the result entry
        // to guarantee end-to-end service cycle completion.
        if snap.state.isTerminal, let action = snap.activityActionID {
          while ContinuousClock.now < deadline {
            if await probe.entries().contains(where: { $0.actionID == action && $0.kind == .result }) {
              return try await s.store.requestSnapshot(id) ?? snap
            }
            try await Task.sleep(for: .milliseconds(10))
          }
          break
        }
        return snap
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let state = try await s.store.requestSnapshot(id)?.state
    Issue.record("request never reached \(states.map(\.rawValue).sorted()); state \(state?.rawValue ?? "gone")", sourceLocation: sourceLocation)
    throw CancellationError()
  }

  /// Continuously polls an asynchronous predicate until it evaluates to true or expires against the timeout.
  func until(_ timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never became true")
    throw CancellationError()
  }

  /// Dispatches a generation draft and awaits its transition into a terminal state.
  @discardableResult
  func sendAndWait(_ draft: SendDraft) async throws -> RequestSnapshot {
    let id = try await service.send(draft)
    return try await wait(id)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Decodes base64 inline image payloads embedded in serialized request content parts.
  static func images(in body: [String: Any]) -> [(mime: String, data: Data)] {
    let parts = ((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
    return parts.compactMap { p in
      guard let inline = p["inlineData"] as? [String: String], let b64 = inline["data"], let d = Data(base64Encoded: b64)
      else { return nil }
      return (inline["mimeType"] ?? "", d)
    }
  }
}

/// Transport decorator intercepting and logging dispatched jobs while delegating execution to an underlying transport.
struct RecordingTransport: GenerationTransport {
  let inner: any GenerationTransport
  let jobs: Locked<[TransportJob]>
  var events: AsyncStream<TransportEvent> { inner.events }

  func start(_ job: TransportJob, apiKey: String) throws -> Int {
    jobs.withLock { $0.append(job) }
    return try inner.start(job, apiKey: apiKey)
  }
  func cancel(requestID: UUID) async { await inner.cancel(requestID: requestID) }
  func cancel(taskIdentifier: Int) async { await inner.cancel(taskIdentifier: taskIdentifier) }
  func liveTasks() async -> [LiveTask] { await inner.liveTasks() }
}
