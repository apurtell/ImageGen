import Foundation
import Synchronization

/// The generation transport (D§4.6). Production passes the background configuration; tests and
/// DEBUG mock mode pass an ephemeral one with a mock `URLProtocol`. Delegate callbacks run on a
/// private serial queue and yield events synchronously into one ordered stream.
///
/// Place in the design: this is the network layer. `GenerationService` is its only client. The
/// service calls `start`, `cancel` and `liveTasks`, and it reads `events` in one long-lived task.
/// The transport writes response bytes to disk through `ResponseAccumulator`; it does not parse them.
///
/// Why a delegate and not `async` calls: a background `URLSession` reports results only through
/// delegate callbacks, and those callbacks can arrive in a later process after a relaunch. So the
/// transport turns each callback into a `TransportEvent` and puts it in an `AsyncStream` (see the
/// primer, *AsyncStream*). Each callback yields before it returns. The serial queue runs one callback at
/// a time, so the stream order is the delegate order. A `Task` for each callback would lose that order.
///
/// `@unchecked Sendable`: an `NSObject` subclass can't be checked, but every mutable field is
/// behind a `Mutex`, and the rest are immutable `let`s of `Sendable` types. (See the primer,
/// *Sendable*: `@unchecked` means that the code, not the compiler, guarantees the safety.)
final class URLSessionTransport: NSObject, GenerationTransport, URLSessionDataDelegate, @unchecked Sendable {
  let events: AsyncStream<TransportEvent>
  /// The producer side of `events`. Only the delegate callbacks and the deferred-start task yield to it.
  private let continuation: AsyncStream<TransportEvent>.Continuation
  private let files: FileStore
  private let accumulator: ResponseAccumulator
  private let endpoint: GeminiEndpoint
  /// Waits out a retry delay on a non-background configuration. Tests inject an instant or a manually
  /// advanced one.
  private let sleeper: @Sendable (Duration) async -> Void
  /// A test hook that can change each request before its task is made.
  private let requestDecorator: (@Sendable (inout URLRequest) -> Void)?
  private let isBackground: Bool
  var isBackgroundSession: Bool { isBackground }
  /// The session takes `self` as its delegate, so it can only be made after `super.init()`. Swift needs
  /// every `let` to have a value before that call, so the session lives in a box that `init` fills
  /// later. After `init` the box always holds a session.
  private let sessionBox = Mutex<URLSession?>(nil)

  /// Per-task bookkeeping, keyed by task identifier. Delegate callbacks and the client's calls both
  /// change it, from different threads, so it is behind the `state` mutex.
  private struct State {
    /// When each task began (resumed, or its delayed start fired), for `elapsed`.
    var startedAt: [Int: ContinuousClock.Instant] = [:]
    /// From the metrics callback, which comes just before completion; used after a relaunch.
    var metricsDuration: [Int: Duration] = [:]
    /// Tasks held un-resumed until their delay passes (non-background configurations only).
    var deferred: [Int: (requestID: UUID, attempt: Int, task: URLSessionTask)] = [:]
  }

  private let state = Mutex(State())

  init(
    configuration: URLSessionConfiguration, files: FileStore, endpoint: GeminiEndpoint = GeminiEndpoint(),
    sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },  // Cancellation only ends the wait early.
    requestDecorator: (@Sendable (inout URLRequest) -> Void)? = nil
  ) {
    // The stream first, then the session: events delivered before anyone listens are buffered.
    // On a background relaunch the system can deliver completions as soon as the session exists,
    // before `GenerationService` reads the stream. `.unbounded` keeps every one of them.
    let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    events = stream
    self.continuation = continuation
    self.files = files
    accumulator = ResponseAccumulator(files: files)
    self.endpoint = endpoint
    self.sleeper = sleeper
    self.requestDecorator = requestDecorator
    isBackground = configuration.identifier != nil
    super.init()
    // One operation at a time: this is what makes the delegate callbacks, and so the events, ordered.
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "transport.delegate"
    // Making a background session with an existing identifier reconnects to the system's transfers
    // for that identifier, including tasks from an earlier process.
    sessionBox.withLock { $0 = URLSession(configuration: configuration, delegate: self, delegateQueue: queue) }
  }

  private var session: URLSession { sessionBox.withLock { $0! } }

  /// The production configuration (D§4.6). `waitsForConnectivity` is deliberately left unset.
  /// Background sessions ignore it and always wait for connectivity.
  static func backgroundConfiguration(bundleID: String) -> URLSessionConfiguration {
    let c = URLSessionConfiguration.background(withIdentifier: "\(bundleID).generation")
    c.isDiscretionary = false
    // Lets iOS start the app in the background when a transfer finishes.
    c.sessionSendsLaunchEvents = true
    // 300 s is idle time: generation can be silent for over 60 s.
    c.timeoutIntervalForRequest = 300
    c.timeoutIntervalForResource = 1800
    c.httpMaximumConnectionsPerHost = 4
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.urlCache = nil
    return c
  }

  /// Timeouts for a non-background configuration, matching the background ones.
  static func ephemeralConfiguration(protocolClasses: [AnyClass] = []) -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 300
    c.timeoutIntervalForResource = 1800
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.urlCache = nil
    if !protocolClasses.isEmpty { c.protocolClasses = protocolClasses }
    return c
  }

  /// Cancels every task and ends the event stream, without waiting for the session to wind down.
  func invalidate() {
    session.invalidateAndCancel()
    continuation.finish()
  }

  /// Signaled once, by `didBecomeInvalidWithError`, after the session has delivered its last callback.
  private let invalidated = DispatchSemaphore(value: 0)

  /// Cancels everything and waits (up to `timeout`) until the session has delivered every task's
  /// completion and become invalid, so no callback can touch files afterwards (tests).
  /// It blocks the calling thread, so it must never run on the delegate queue.
  func invalidateAndWait(timeout: TimeInterval = 2) {
    session.invalidateAndCancel()
    _ = invalidated.wait(timeout: .now() + timeout)
    continuation.finish()
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    invalidated.signal()
  }

  // MARK: GenerationTransport

  /// Makes the upload task for one attempt and starts it, at once or after `earliestBegin`.
  /// Called by `GenerationService` (an actor). It does not await, so the checks that the caller makes
  /// before it stay valid until the task exists.
  func start(_ job: TransportJob, apiKey: String) throws -> Int {
    var request = endpoint.generateContentRequest(modelID: job.modelID, apiKey: apiKey, bodySize: job.bodySize)
    // `&request` passes the request `inout`: the decorator can change this local copy in place.
    requestDecorator?(&request)
    // The empty `.part` file exists before the task does, so no callback can find it missing.
    try accumulator.prepareNewAttempt(requestID: job.requestID, attempt: job.attempt)
    let task = session.uploadTask(with: request, fromFile: job.bodyURL)
    task.taskDescription = TaskDescription.make(requestID: job.requestID, attempt: job.attempt)
    task.countOfBytesClientExpectsToSend = Int64(job.bodySize)
    task.countOfBytesClientExpectsToReceive = Int64(job.expectedReceiveBytes)
    let id = task.taskIdentifier

    guard let begin = job.earliestBegin else {
      // `startedAt` is written before `resume`, so the completion callback always finds it.
      state.withLock { $0.startedAt[id] = .now }
      task.resume()
      return id
    }
    if isBackground {
      // The system starts it later and calls willBeginDelayedRequest.
      task.earliestBeginDate = begin
      task.resume()
    } else {
      // earliestBeginDate is ignored outside background sessions, so hold the task and resume it ourselves.
      let delay = Duration.seconds(max(0, begin.timeIntervalSinceNow))
      // Copied into locals so that the closure below captures plain values, not `self` or `job`.
      let sleeper = self.sleeper
      let requestID = job.requestID
      let attempt = job.attempt
      // The task is in `deferred` before the sleep starts, so a `cancel` that comes during the sleep
      // finds it there.
      state.withLock { $0.deferred[id] = (requestID, attempt, task) }
      // `Task.detached` runs the wait with no actor, so it does not hold up the caller. `[weak self]`
      // lets a test release the transport while the wait is still running.
      Task.detached { [weak self] in
        await sleeper(delay)
        guard let self else { return }
        // Gone from the map: cancelled while waiting.
        // The check and the removal are one step under the lock, so a cancel and this resume can't both
        // act on the task.
        guard self.state.withLock({ s -> Bool in
          guard s.deferred.removeValue(forKey: id) != nil else { return false }
          s.startedAt[id] = .now
          return true
        }) else { return }
        task.resume()
        self.continuation.yield(.began(requestID: requestID, attempt: attempt, taskIdentifier: id))
      }
    }
    return id
  }

  /// Cancels the request's held tasks first, then its live ones. Each cancelled task still delivers a
  /// completion (with `NSURLErrorCancelled`), which is how the service learns about it.
  func cancel(requestID: UUID) async {
    cancelDeferred { $0.requestID == requestID }
    // `allTasks` awaits the session, so this is a suspension point.
    for task in await session.allTasks where TaskDescription.parse(task.taskDescription)?.requestID == requestID {
      task.cancel()
    }
  }

  func cancel(taskIdentifier: Int) async {
    cancelDeferred { $0.task.taskIdentifier == taskIdentifier }
    for task in await session.allTasks where task.taskIdentifier == taskIdentifier {
      task.cancel()
    }
  }

  /// A held task is cancelled and resumed, so its cancellation is delivered to the delegate.
  /// The matching tasks leave the map under the lock; `cancel` and `resume` run after the lock is free.
  private func cancelDeferred(where match: ((requestID: UUID, attempt: Int, task: URLSessionTask)) -> Bool) {
    let tasks = state.withLock { s in
      let hits = s.deferred.filter { match($0.value) }
      for key in hits.keys { s.deferred[key] = nil }
      return hits.values.map(\.task)
    }
    for task in tasks {
      task.cancel()
      task.resume()
    }
  }

  /// The tasks that are held or still running, for the Reconciler (D§4.7). Held tasks report 0 bytes
  /// sent, so they read as "not begun".
  func liveTasks() async -> [LiveTask] {
    let held = state.withLock { s in
      s.deferred.map { LiveTask(requestID: $0.value.requestID, attempt: $0.value.attempt, taskIdentifier: $0.key, countOfBytesSent: 0) }
    }
    let heldIDs = Set(held.map(\.taskIdentifier))
    // A held task is also in `allTasks` (in the suspended state); skip it, so it is not listed twice.
    return held + (await session.allTasks).compactMap { task in
      guard !heldIDs.contains(task.taskIdentifier) else { return nil }
      guard task.state == .running || task.state == .suspended,
        let (id, attempt) = TaskDescription.parse(task.taskDescription)
      else { return nil }
      return LiveTask(requestID: id, attempt: attempt, taskIdentifier: task.taskIdentifier, countOfBytesSent: task.countOfBytesSent)
    }
  }

  // MARK: Delegate (on the private serial queue)

  // Every method below runs on the serial delegate queue, one at a time. None of them awaits: each one
  // finishes its file work and its `yield` before it returns, which keeps the events in delegate order.

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let (id, attempt) = TaskDescription.parse(dataTask.taskDescription) else { return }
    accumulator.append(data, requestID: id, attempt: attempt, taskIdentifier: dataTask.taskIdentifier)
  }

  /// A background session calls this when a delayed retry task is about to start.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willBeginDelayedRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
  ) {
    completionHandler(.continueLoading, nil)
    guard let (id, attempt) = TaskDescription.parse(task.taskDescription) else { return }
    state.withLock { $0.startedAt[task.taskIdentifier] = .now }
    continuation.yield(.began(requestID: id, attempt: attempt, taskIdentifier: task.taskIdentifier))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    state.withLock { $0.metricsDuration[task.taskIdentifier] = .seconds(metrics.taskInterval.duration) }
  }

  /// The end of one task, for every outcome: success, HTTP error, network error or cancel.
  /// Exactly one `.completed` event is yielded for each task that this app made.
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard let (id, attempt) = TaskDescription.parse(task.taskDescription) else { return }
    let http = task.response as? HTTPURLResponse
    let status = error == nil ? http?.statusCode : nil
    // The file is closed and the `.complete` marker written before the event is yielded, so the
    // service never parses a file that is still open.
    let (part, bytes) = accumulator.complete(
      requestID: id, attempt: attempt, taskIdentifier: task.taskIdentifier, httpStatus: status)
    var headers: [String: String] = [:]
    for (k, v) in http?.allHeaderFields ?? [:] {
      if let k = k as? String, let v = v as? String { headers[k] = v }
    }
    let nsError = error as NSError?
    let elapsed: Duration = state.withLock { s in
      // `defer` runs when the closure returns, on both paths: the task's entries never outlive it.
      defer {
        s.startedAt[task.taskIdentifier] = nil
        s.metricsDuration[task.taskIdentifier] = nil
      }
      // A task from an earlier process has no `startedAt` here, so the metrics duration stands in.
      if let start = s.startedAt[task.taskIdentifier] { return .now - start }
      return s.metricsDuration[task.taskIdentifier] ?? .zero
    }
    let completion = TransportCompletion(
      requestID: id, attempt: attempt, taskIdentifier: task.taskIdentifier, httpStatus: status, headers: headers,
      partURL: part, bytesReceived: bytes,
      error: nsError.map { URLError.Code(rawValue: $0.domain == NSURLErrorDomain ? $0.code : NSURLErrorUnknown) },
      cancelReason: nsError?.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int,
      elapsed: elapsed)
    continuation.yield(.completed(completion))
  }

  /// The system calls this after it has delivered every event of a background wake. It comes on the
  /// same queue, after every earlier callback, so this event is behind every earlier `.completed`.
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    continuation.yield(.finishedEvents(sessionIdentifier: session.configuration.identifier ?? ""))
  }
}
