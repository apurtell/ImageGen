import Foundation

/// Defines the transport boundary abstractions between generation orchestration (`GenerationService`)
/// and the underlying URLSession networking infrastructure (`URLSessionTransport`).
///
/// All boundary structures conform to `Sendable` to enable thread-safe cross-actor communication between
/// background session delegate queues and the generation service actor.

/// Encapsulates the execution parameters required to initiate an individual HTTP generation attempt.
struct TransportJob: Sendable, Equatable {
  let requestID: UUID
  /// Sequence index for this execution attempt.
  let attempt: Int
  let modelID: String
  /// File system URL pointing to the serialized JSON request body, required for background upload persistence.
  let bodyURL: URL
  let bodySize: Int
  let expectedReceiveBytes: Int
  /// Earliest start schedule for delayed retry attempts, or nil for immediate transmission.
  let earliestBegin: Date?
}

/// Structured outcome resulting from task completion within the transport delegate.
struct TransportCompletion: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let taskIdentifier: Int
  /// Upstream HTTP status code, or nil if aborted prior to response receipt.
  let httpStatus: Int?
  let headers: [String: String]
  /// File path containing the downloaded response body payload.
  let partURL: URL
  let bytesReceived: Int
  let error: URLError.Code?
  /// Reason code extracted from `NSURLErrorBackgroundTaskCancelledReasonKey` to differentiate user aborts from system eviction.
  let cancelReason: Int?
  /// Total elapsed network transfer duration utilized for adaptive retry policy evaluation.
  let elapsed: Duration
}

/// Discrete lifecycle events emitted across the transport event channel.
enum TransportEvent: Sendable, Equatable {
  /// Emitted when a scheduled background retry transitions into active network transmission.
  case began(requestID: UUID, attempt: Int, taskIdentifier: Int)
  case completed(TransportCompletion)
  /// Terminal signal indicating that all background wake delegate callbacks have finished processing.
  case finishedEvents(sessionIdentifier: String)
}

/// Metadata snapshot of an active network transfer registered with the background session manager.
struct LiveTask: Sendable, Equatable {
  let requestID: UUID
  let attempt: Int
  let taskIdentifier: Int
  /// Byte counter distinguishing actively uploading tasks from queued delayed tasks.
  let countOfBytesSent: Int64
}

/// Primary networking interface orchestrating Gemini API generation requests.
///
/// Architecture & Contract:
/// - Provides a singular, sequential `events` stream consumed by `GenerationService`.
/// - `start` is executed synchronously without actor suspension points to eliminate race conditions
///   between user-directed cancellation and task instantiation.
/// - Manages background session upload tasks and supports state recovery across application restarts.
protocol GenerationTransport: Sendable {
  var events: AsyncStream<TransportEvent> { get }
  /// Initiates an upload task synchronously, returning the assigned URLSession task identifier.
  func start(_ job: TransportJob, apiKey: String) throws -> Int
  /// Terminates all active or scheduled tasks associated with the specified request identifier.
  func cancel(requestID: UUID) async
  /// Cancels a specific task by its runtime identifier.
  func cancel(taskIdentifier: Int) async
  /// Enumerates all active tasks currently tracked by the underlying session.
  func liveTasks() async -> [LiveTask]
}

/// Serialization utilities for encoding and decoding request metadata into URLSession task descriptions.
///
/// Survives application lifecycle termination, allowing recreated background sessions to correlate
/// in-flight tasks with their originating database requests upon process restart.
enum TaskDescription {
  static func make(requestID: UUID, attempt: Int) -> String { "gen:\(requestID.uuidString):\(attempt)" }

  /// Parses task description strings conforming to the `gen:<uuid>:<attempt>` schema.
  static func parse(_ s: String?) -> (requestID: UUID, attempt: Int)? {
    guard let parts = s?.split(separator: ":"), parts.count == 3, parts[0] == "gen",
      let id = UUID(uuidString: String(parts[1])), let attempt = Int(parts[2])
    else { return nil }
    return (id, attempt)
  }
}

/// Computes upper-bound transfer estimates for `countOfBytesClientExpectsToReceive` to inform OS scheduling.
func expectedReceiveBytes(imageSize: ImageSize?) -> Int {
  switch imageSize {
  case .s512: 1_000_000
  case .s1K, nil: 3_000_000
  case .s2K: 8_000_000
  case .s4K: 24_000_000
  }
}
