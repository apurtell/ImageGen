import Foundation

// The transport boundary (D§4.6): the values that cross between `GenerationService` (the generation
// layer) and `URLSessionTransport` (the network layer), and the protocol that the service uses.
// Every type here is a `Sendable` value type, because the service is an actor and the transport runs
// its callbacks on its own queue (see the primer, *Sendable*). The protocol lets tests supply a fake
// transport.

/// What `GenerationService` asks the transport to send: one HTTP attempt for one request.
struct TransportJob: Sendable, Equatable {
  let requestID: UUID
  /// The attempt number. Each attempt has its own task and its own `.part` response file.
  let attempt: Int
  let modelID: String
  /// The prepared `body.json`. The upload reads the body from this file, because only a file body
  /// survives when the app exits (D§4.6).
  let bodyURL: URL
  let bodySize: Int
  let expectedReceiveBytes: Int
  /// A retry's delay (D§4.6, Retries); nil starts at once.
  let earliestBegin: Date?
}

/// The result of one finished task, built in the delegate's completion callback.
struct TransportCompletion: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let taskIdentifier: Int
  /// nil when the task failed with an error (no usable HTTP response).
  let httpStatus: Int?
  let headers: [String: String]
  /// The complete response body on disk; `GenerationService` parses it from this file.
  let partURL: URL
  let bytesReceived: Int
  let error: URLError.Code?
  /// `NSURLErrorBackgroundTaskCancelledReasonKey`, if present.
  ///
  /// It tells a system cancel (for example a force-quit) from a user Stop (D§4.6, "Who cancelled").
  let cancelReason: Int?
  /// Since the task began (for `RetryPolicy`).
  let elapsed: Duration
}

/// One event in the transport's ordered stream. This is an enum with associated values: each case
/// carries its own data (see the primer, *Types and values*).
enum TransportEvent: Sendable, Equatable {
  /// A delayed retry task started. It moves the request from `retryScheduled` to `inFlight`.
  case began(requestID: UUID, attempt: Int, taskIdentifier: Int)
  case completed(TransportCompletion)
  /// The system delivered every event of a background wake. The service then calls the system's
  /// completion handler through `BackgroundEventsRelay`.
  case finishedEvents(sessionIdentifier: String)
}

/// A task that the session still runs or holds. The Reconciler compares these with the stored requests
/// after a launch (D§4.7).
struct LiveTask: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let taskIdentifier: Int
  /// More than 0 means that a delayed retry has begun.
  let countOfBytesSent: Int64
}

/// Generation's only path to the network (D§4.6). The event stream exists from `init`, so nothing
/// can be delivered before its one consumer, `GenerationService`, is listening.
///
/// Invariant: `events` has exactly one consumer. That consumer handles each event to the end before it
/// reads the next, so `.finishedEvents` is handled after every earlier `.completed`.
protocol GenerationTransport: Sendable {
  var events: AsyncStream<TransportEvent> { get }
  /// Returns the task identifier.
  ///
  /// It is synchronous on purpose: the caller's Stop check and the task creation happen with no
  /// suspension point between them ("Remembered intent" in the primer, *Patterns used in this project*).
  func start(_ job: TransportJob, apiKey: String) throws -> Int
  /// Cancels every task of the request, including a delayed retry that has not started.
  func cancel(requestID: UUID) async
  /// Replacing a background-created retry.
  func cancel(taskIdentifier: Int) async
  func liveTasks() async -> [LiveTask]
}

/// `"gen:<uuid>:<attempt>"`, the task description that survives a relaunch.
///
/// After a relaunch, the recreated session reports the old tasks with only their identifiers and this
/// string. The string is how the transport maps a task back to its request and attempt.
enum TaskDescription {
  static func make(requestID: UUID, attempt: Int) -> String { "gen:\(requestID.uuidString):\(attempt)" }

  /// nil for a string in any other format, so a task that this app did not make is ignored.
  static func parse(_ s: String?) -> (requestID: UUID, attempt: Int)? {
    guard let parts = s?.split(separator: ":"), parts.count == 3, parts[0] == "gen",
      let id = UUID(uuidString: String(parts[1])), let attempt = Int(parts[2])
    else { return nil }
    return (id, attempt)
  }
}

/// The expected response size for `countOfBytesClientExpectsToReceive` (D§4.6): per image,
/// 512 → 1 MB, 1K → 3 MB, 2K → 8 MB, 4K → 24 MB; a model with no size setting counts as 1K.
/// The system uses the estimate to schedule background transfers.
func expectedReceiveBytes(imageSize: ImageSize?) -> Int {
  switch imageSize {
  case .s512: 1_000_000
  case .s1K, nil: 3_000_000
  case .s2K: 8_000_000
  case .s4K: 24_000_000
  }
}
