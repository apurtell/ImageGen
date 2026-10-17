import Foundation
import Synchronization

/// URLSession network transport orchestrating background and ephemeral generation HTTP uploads.
///
/// Architecture:
/// - Provides the core network transport layer consumed exclusively by `GenerationService`.
/// - Delegates all background transfer outcomes and data chunks through a private serial `OperationQueue`,
///   yielding events into an `AsyncStream` to ensure strict FIFO sequencing without task interleaving.
/// - Pairs with `ResponseAccumulator` to write streaming response payloads directly to disk, keeping
///   memory usage bounded and decoupling network delivery from content parsing.
/// - Concurrency guarantees: Although subclassing `NSObject` requires `@unchecked Sendable`, thread safety
///   is rigorously enforced via `Mutex` synchronization around mutable state, while delegate dispatch
///   is serialized on a dedicated queue.
final class URLSessionTransport: NSObject, GenerationTransport, URLSessionDataDelegate, @unchecked Sendable {
  let events: AsyncStream<TransportEvent>
  /// Event producer driving downstream consumers in `GenerationService`.
  private let continuation: AsyncStream<TransportEvent>.Continuation
  private let files: FileStore
  private let accumulator: ResponseAccumulator
  private let endpoint: GeminiEndpoint
  /// Suspension hook mediating retry delays in non-background execution contexts.
  private let sleeper: @Sendable (Duration) async -> Void
  /// Test interception hook for mutating outbound requests prior to task creation.
  private let requestDecorator: (@Sendable (inout URLRequest) -> Void)?
  private let isBackground: Bool
  var isBackgroundSession: Bool { isBackground }
  /// Deferred session container to allow passing `self` as the delegate following base initialization.
  private let sessionBox = Mutex<URLSession?>(nil)

  /// Internal task state synchronized across delegate callbacks and external control invocations.
  private struct State {
    /// Timestamp marking transmission start for elapsed duration tracking.
    var startedAt: [Int: ContinuousClock.Instant] = [:]
    /// Fallback duration metric recorded via session task metrics for tasks resumed across restarts.
    var metricsDuration: [Int: Duration] = [:]
    /// Retained tasks pending delay expiration under non-background session configurations.
    var deferred: [Int: (requestID: UUID, attempt: Int, task: URLSessionTask)] = [:]
  }

  private let state = Mutex(State())

  init(
    configuration: URLSessionConfiguration, files: FileStore, endpoint: GeminiEndpoint = GeminiEndpoint(),
    sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    requestDecorator: (@Sendable (inout URLRequest) -> Void)? = nil
  ) {
    // Construct the event channel prior to session initialization so that early arrivals on relaunch are buffered.
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
    // Serial delegate queue ensures linear processing and determinism for incoming delegate callbacks.
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "transport.delegate"
    // Reconnecting to a background identifier reclaims active and pending transfers across process terminations.
    sessionBox.withLock { $0 = URLSession(configuration: configuration, delegate: self, delegateQueue: queue) }
  }

  private var session: URLSession { sessionBox.withLock { $0! } }

  /// Constructs the default background session configuration for generation transfers.
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

  /// Constructs an ephemeral configuration for testing and mock network execution.
  static func ephemeralConfiguration(protocolClasses: [AnyClass] = []) -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 300
    c.timeoutIntervalForResource = 1800
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.urlCache = nil
    if !protocolClasses.isEmpty { c.protocolClasses = protocolClasses }
    return c
  }

  /// Cancels in-flight tasks and terminates the transport event stream.
  func invalidate() {
    session.invalidateAndCancel()
    continuation.finish()
  }

  /// Synchronization semaphore signaled when session invalidation fully concludes.
  private let invalidated = DispatchSemaphore(value: 0)

  /// Cancels all active operations and synchronously awaits full delegate invalidation.
  func invalidateAndWait(timeout: TimeInterval = 2) {
    session.invalidateAndCancel()
    _ = invalidated.wait(timeout: .now() + timeout)
    continuation.finish()
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    invalidated.signal()
  }

  /// Instantiates and schedules an upload task for a specific generation attempt.
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
      task.earliestBeginDate = begin
      task.resume()
    } else {
      let delay = Duration.seconds(max(0, begin.timeIntervalSinceNow))
      let sleeper = self.sleeper
      let requestID = job.requestID
      let attempt = job.attempt
      state.withLock { $0.deferred[id] = (requestID, attempt, task) }
      Task.detached { [weak self] in
        await sleeper(delay)
        guard let self else { return }
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

  /// Cancels deferred and active tasks associated with the specified request identifier.
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

  /// Cancels deferred tasks and resumes them to ensure delegate completion routing.
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

  /// Queries all currently managed tasks across active and deferred states for reconciliation.
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

  /// Invoked when a delayed background transfer initiates active transmission.
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

  /// Processes transfer termination, closes disk files, and emits corresponding completion telemetry.
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

  /// Emitted when all pending background delegate events have been delivered.
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    continuation.yield(.finishedEvents(sessionIdentifier: session.configuration.identifier ?? ""))
  }
}
