import Foundation

struct TransportJob: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let modelID: String
  let bodyURL: URL
  let bodySize: Int
  let expectedReceiveBytes: Int
  /// A retry's delay (D§4.6, Retries); nil starts at once.
  let earliestBegin: Date?
}

struct TransportCompletion: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let taskIdentifier: Int
  let httpStatus: Int?
  let headers: [String: String]
  let partURL: URL
  let bytesReceived: Int
  let error: URLError.Code?
  /// `NSURLErrorBackgroundTaskCancelledReasonKey`, if present.
  let cancelReason: Int?
  /// Since the task began (for `RetryPolicy`).
  let elapsed: Duration
}

enum TransportEvent: Sendable, Equatable {
  case began(requestID: UUID, attempt: Int, taskIdentifier: Int)
  case completed(TransportCompletion)
  case finishedEvents(sessionIdentifier: String)
}

struct LiveTask: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let taskIdentifier: Int
  let countOfBytesSent: Int64
}

/// Generation's only path to the network (D§4.6). The event stream exists from `init`, so nothing
/// can be delivered before its one consumer, `GenerationService`, is listening.
protocol GenerationTransport: Sendable {
  var events: AsyncStream<TransportEvent> { get }
  /// Returns the task identifier.
  func start(_ job: TransportJob, apiKey: String) throws -> Int
  func cancel(requestID: UUID) async
  /// Replacing a background-created retry.
  func cancel(taskIdentifier: Int) async
  func liveTasks() async -> [LiveTask]
}

/// `"gen:<uuid>:<attempt>"`, the task description that survives a relaunch.
enum TaskDescription {
  static func make(requestID: UUID, attempt: Int) -> String { "gen:\(requestID.uuidString):\(attempt)" }

  static func parse(_ s: String?) -> (requestID: UUID, attempt: Int)? {
    guard let parts = s?.split(separator: ":"), parts.count == 3, parts[0] == "gen",
      let id = UUID(uuidString: String(parts[1])), let attempt = Int(parts[2])
    else { return nil }
    return (id, attempt)
  }
}

/// The expected response size for `countOfBytesClientExpectsToReceive` (D§4.6): per image,
/// 512 → 1 MB, 1K → 3 MB, 2K → 8 MB, 4K → 24 MB; a model with no size setting counts as 1K.
func expectedReceiveBytes(imageSize: ImageSize?) -> Int {
  switch imageSize {
  case .s512: 1_000_000
  case .s1K, nil: 3_000_000
  case .s2K: 8_000_000
  case .s4K: 24_000_000
  }
}
