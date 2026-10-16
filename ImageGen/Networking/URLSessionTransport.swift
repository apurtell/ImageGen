import Foundation
import Synchronization

/// The generation transport (D§4.6). Production passes the background configuration; tests and
/// DEBUG mock mode pass an ephemeral one with a mock `URLProtocol`. Delegate callbacks run on a
/// private serial queue and yield events synchronously into one ordered stream.
///
/// `@unchecked Sendable`: an `NSObject` subclass can't be checked, but every mutable field is
/// behind a `Mutex`, and the rest are immutable `let`s of `Sendable` types.
final class URLSessionTransport: NSObject, GenerationTransport, URLSessionDataDelegate, @unchecked Sendable {
  let events: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation
  private let files: FileStore
  private let accumulator: ResponseAccumulator
  private let endpoint: GeminiEndpoint
  private let sleeper: @Sendable (Duration) async -> Void
  private let requestDecorator: (@Sendable (inout URLRequest) -> Void)?
  private let isBackground: Bool
  var isBackgroundSession: Bool { isBackground }
  private let sessionBox = Mutex<URLSession?>(nil)

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
    sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    requestDecorator: (@Sendable (inout URLRequest) -> Void)? = nil
  ) {
    // The stream first, then the session: events delivered before anyone listens are buffered.
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
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "transport.delegate"
    sessionBox.withLock { $0 = URLSession(configuration: configuration, delegate: self, delegateQueue: queue) }
  }

  private var session: URLSession { sessionBox.withLock { $0! } }

  /// The production configuration (D§4.6). `waitsForConnectivity` is deliberately left unset.
  static func backgroundConfiguration(bundleID: String) -> URLSessionConfiguration {
    let c = URLSessionConfiguration.background(withIdentifier: "\(bundleID).generation")
    c.isDiscretionary = false
    c.sessionSendsLaunchEvents = true
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

  func invalidate() {
    session.invalidateAndCancel()
    continuation.finish()
  }

  private let invalidated = DispatchSemaphore(value: 0)

  /// Cancels everything and waits (up to `timeout`) until the session has delivered every task's
  /// completion and become invalid, so no callback can touch files afterwards (tests).
  func invalidateAndWait(timeout: TimeInterval = 2) {
    session.invalidateAndCancel()
    _ = invalidated.wait(timeout: .now() + timeout)
    continuation.finish()
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    invalidated.signal()
  }

  // MARK: GenerationTransport

  func start(_ job: TransportJob, apiKey: String) throws -> Int {
    var request = endpoint.generateContentRequest(modelID: job.modelID, apiKey: apiKey, bodySize: job.bodySize)
    requestDecorator?(&request)
    try accumulator.prepareNewAttempt(requestID: job.requestID, attempt: job.attempt)
    let task = session.uploadTask(with: request, fromFile: job.bodyURL)
    task.taskDescription = TaskDescription.make(requestID: job.requestID, attempt: job.attempt)
    task.countOfBytesClientExpectsToSend = Int64(job.bodySize)
    task.countOfBytesClientExpectsToReceive = Int64(job.expectedReceiveBytes)
    let id = task.taskIdentifier

    guard let begin = job.earliestBegin else {
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
      let sleeper = self.sleeper
      let requestID = job.requestID
      let attempt = job.attempt
      state.withLock { $0.deferred[id] = (requestID, attempt, task) }
      Task.detached { [weak self] in
        await sleeper(delay)
        guard let self else { return }
        // Gone from the map: cancelled while waiting.
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

  func cancel(requestID: UUID) async {
    cancelDeferred { $0.requestID == requestID }
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

  func liveTasks() async -> [LiveTask] {
    let held = state.withLock { s in
      s.deferred.map { LiveTask(requestID: $0.value.requestID, attempt: $0.value.attempt, taskIdentifier: $0.key, countOfBytesSent: 0) }
    }
    let heldIDs = Set(held.map(\.taskIdentifier))
    return held + (await session.allTasks).compactMap { task in
      guard !heldIDs.contains(task.taskIdentifier) else { return nil }
      guard task.state == .running || task.state == .suspended,
        let (id, attempt) = TaskDescription.parse(task.taskDescription)
      else { return nil }
      return LiveTask(requestID: id, attempt: attempt, taskIdentifier: task.taskIdentifier, countOfBytesSent: task.countOfBytesSent)
    }
  }

  // MARK: Delegate (on the private serial queue)

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

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard let (id, attempt) = TaskDescription.parse(task.taskDescription) else { return }
    let http = task.response as? HTTPURLResponse
    let status = error == nil ? http?.statusCode : nil
    let (part, bytes) = accumulator.complete(
      requestID: id, attempt: attempt, taskIdentifier: task.taskIdentifier, httpStatus: status)
    var headers: [String: String] = [:]
    for (k, v) in http?.allHeaderFields ?? [:] {
      if let k = k as? String, let v = v as? String { headers[k] = v }
    }
    let nsError = error as NSError?
    let elapsed: Duration = state.withLock { s in
      defer {
        s.startedAt[task.taskIdentifier] = nil
        s.metricsDuration[task.taskIdentifier] = nil
      }
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

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    continuation.yield(.finishedEvents(sessionIdentifier: session.configuration.identifier ?? ""))
  }
}
