import Foundation
import OSLog
import Synchronization

/// Structured log message supporting compile time string interpolation and privacy segmentation.
/// Private segments are masked in public diagnostic logs while preserved in internal activity files.
struct ActivityMessage: Sendable, Equatable, ExpressibleByStringInterpolation {
  struct Segment: Sendable, Equatable {
    var text: String
    var isPrivate: Bool
  }

  var segments: [Segment]

  init(segments: [Segment]) { self.segments = segments }

  init(stringLiteral value: String) {
    segments = value.isEmpty ? [] : [Segment(text: value, isPrivate: false)]
  }

  init(stringInterpolation: StringInterpolation) {
    segments = stringInterpolation.segments
  }

  /// Interpolation builder accumulating text fragments and privacy tags.
  struct StringInterpolation: StringInterpolationProtocol {
    var segments: [Segment] = []

    init(literalCapacity: Int, interpolationCount: Int) {}

    mutating func appendLiteral(_ literal: String) {
      append(literal, isPrivate: false)
    }

    mutating func appendInterpolation<T>(_ value: T) {
      append(String(describing: value), isPrivate: false)
    }

    mutating func appendInterpolation<T>(private value: T) {
      append(String(describing: value), isPrivate: true)
    }

    /// Appends text fragment, coalescing adjacent segments sharing identical privacy annotations.
    private mutating func append(_ text: String, isPrivate: Bool) {
      guard !text.isEmpty else { return }
      if let last = segments.last, last.isPrivate == isPrivate {
        segments[segments.count - 1].text += text
      } else {
        segments.append(Segment(text: text, isPrivate: isPrivate))
      }
    }
  }

  var plainText: String { segments.map(\.text).joined() }
}

/// Sanitized and rendered variants of an activity message tailored for disk persistence and system logging.
struct RenderedMessage: Sendable {
  var fileText: String
  /// Public log representation with redacted private segments.
  var publicText: String
  /// Extracted private content for privileged diagnostic mirrors.
  var privateText: String

  static func plain(_ text: String) -> RenderedMessage {
    RenderedMessage(fileText: text, publicText: text, privateText: "")
  }
}

/// Command and telemetry event envelope passed through the activity log event pipeline to `ActivityLogStore`.
///
/// Log entries represent sequential operational records. Control events carry completion continuations
/// that synchronize callers with backend store execution order.
enum ActivityLogEvent: Sendable {
  case entry(ActivityEntry, RenderedMessage)
  case resultOfOpenChild(name: String, parent: ActionID, outcome: ActivityOutcome, timestamp: Date, RenderedMessage)
  case flush(CheckedContinuation<Void, Never>)
  case entriesTree(ActionID, CheckedContinuation<[ActivityEntry], Never>)
  case entriesAfter(Int, CheckedContinuation<[(Int, ActivityEntry)], Never>)
  case openActionsAtLaunch(CheckedContinuation<[ActivityEntry], Never>)
  case actionRecords(CheckedContinuation<[ActionRecord], Never>)
  case status(CheckedContinuation<ActivityLogStatus, Never>)
  case clear(id: ActionID, timestamp: Date, CheckedContinuation<Void, Never>)
  case subscribe(AsyncStream<ActivityLogStatus>.Continuation)

  /// Resumes any pending continuation with empty or default values if the downstream store stream has terminated.
  func answerUndelivered() {
    switch self {
    case .entry, .resultOfOpenChild: break
    case .flush(let c): c.resume()
    case .entriesTree(_, let c): c.resume(returning: [])
    case .entriesAfter(_, let c): c.resume(returning: [])
    case .openActionsAtLaunch(let c): c.resume(returning: [])
    case .actionRecords(let c): c.resume(returning: [])
    case .status(let c): c.resume(returning: ActivityLogStatus(lastSequence: 0, lastActionID: nil, lastErrorID: nil))
    case .clear(_, _, let c): c.resume()
    case .subscribe(let c): c.finish()
    }
  }
}

/// Primary synchronous facade for activity logging across the application.
///
/// Designed to be non-blocking and callable from any concurrency domain without suspension. Messages are
/// sanitized and rendered on caller execution contexts before sequence assignment under a lightweight mutex.
/// All events are routed through an ordered asynchronous stream consumed exclusively by `ActivityLogStore`.
final class ActivityLog: Sendable {
  /// Multiplicative constant applied across 16-bit sequence counters to disperse consecutive action IDs.
  static let idMultiplier: UInt16 = 0x9E37
  /// Modular multiplicative inverse of `idMultiplier` modulo 2^16.
  static let idInverse: UInt16 = {
    // Newton's iteration for the inverse of an odd number modulo 2^16.
    var x = idMultiplier
    for _ in 0..<5 { x = x &* (2 &- idMultiplier &* x) }
    return x
  }()

  static func actionID(counter: UInt16) -> ActionID {
    ActionID(raw: String(format: "%04x", counter &* idMultiplier))
  }

  /// Recovers the underlying sequence counter from a hex action identifier.
  static func counter(of id: ActionID) -> UInt16? {
    UInt16(id.raw, radix: 16).map { $0 &* idInverse }
  }

  private struct State {
    var nextCounter: UInt16
  }

  /// Synchronizes counter increments and ensures stream submission preserves strict serialization order.
  private let state: Mutex<State>
  /// Unbounded event stream feeding the backend storage actor.
  private let continuation: AsyncStream<ActivityLogEvent>.Continuation
  /// Injected sanitizer pass stripping sensitive patterns from formatted log output.
  private let sanitize: @Sendable (String) -> String
  /// Time provider for timestamp generation.
  private let clock: @Sendable () -> Date
  /// Background consumption task managing `ActivityLogStore` execution.
  private let storeTask: Task<Void, Never>
  let fileURL: URL

  init(
    fileURL: URL, sanitize: @escaping @Sendable (String) -> String,
    mirror: @escaping @Sendable (ActivityEntry, _ publicText: String, _ privateText: String) -> Void = ActivityLog.osLogMirror,
    clock: @escaping @Sendable () -> Date = { Date() },
    limits: ActivityLogStore.Limits = .standard
  ) {
    self.fileURL = fileURL
    self.sanitize = sanitize
    self.clock = clock
    let seed = Self.prepareFile(fileURL)
    state = Mutex(State(nextCounter: seed))
    let (stream, continuation) = AsyncStream<ActivityLogEvent>.makeStream()
    self.continuation = continuation
    let store = ActivityLogStore(fileURL: fileURL, mirror: mirror, limits: limits)
    storeTask = Task.detached(priority: .utility) { await store.run(stream) }
  }

  deinit {
    continuation.finish()
  }

  /// Closes the event stream and awaits completion of all pending disk writes in the storage actor.
  func close() async {
    state.withLock { _ in continuation.finish() }
    await storeTask.value
  }

  /// Begins a top-level action. The caller passes the returned ID to `step` and `result`, and must
  /// conclude the action lifecycle with exactly one paired Result entry.
  @discardableResult
  func begin(_ name: String, origin: ActivityOrigin, _ m: ActivityMessage) -> ActionID {
    begin(name, parent: nil, origin: origin, relatedID: nil, m)
  }

  /// Begins a sub-action; the store copies the parent's origin.
  @discardableResult
  func begin(_ name: String, parent: ActionID, _ m: ActivityMessage) -> ActionID {
    begin(name, parent: parent, origin: nil, relatedID: nil, m)
  }

  /// A completion that arrived after its request was marked interrupted (D§4.13).
  /// It is a new top-level action; `relatedID` links it to the original, and Last Error judges the
  /// original by it.
  @discardableResult
  func beginLateCompletion(of original: ActionID, _ m: ActivityMessage) -> ActionID {
    begin("Late completion", parent: nil, origin: .system, relatedID: original, m)
  }

  /// Adds a Step to an action. The facade leaves the name and parent empty; the store fills them in
  /// from its index, which also knows actions adopted from an earlier process.
  func step(_ id: ActionID, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      let entry = ActivityEntry(timestamp: clock(), actionID: id, name: "", kind: .step, message: rendered.fileText)
      continuation.yield(.entry(entry, rendered))
    }
  }

  /// Emits the terminal result of an active action, recording outcome disposition and finalizing its lifecycle.
  func result(_ id: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      let entry = ActivityEntry(
        timestamp: clock(), actionID: id, name: "", kind: .result, outcome: outcome, message: rendered.fileText)
      continuation.yield(.entry(entry, rendered))
    }
  }

  /// Concludes the most recently opened child action matching `name` under `parent`, resolving across process restarts.
  func result(ofOpenChild name: String, of parent: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      _ = continuation.yield(.resultOfOpenChild(name: name, parent: parent, outcome: outcome, timestamp: clock(), rendered))
    }
  }

  /// Allocates the next action ID and enqueues the begin entry atomically under the mutex.
  private func begin(
    _ name: String, parent: ActionID?, origin: ActivityOrigin?, relatedID: ActionID?, _ m: ActivityMessage
  ) -> ActionID {
    let rendered = render(m)
    return state.withLock { s in
      let id = Self.takeID(&s)
      let entry = ActivityEntry(
        timestamp: clock(), actionID: id, parentID: parent, name: name, kind: .begin, origin: origin,
        relatedID: relatedID, message: rendered.fileText)
      continuation.yield(.entry(entry, rendered))
      return id
    }
  }

  /// Sanitizes raw input and extracts privacy segments on the caller thread before stream ingestion.
  private func render(_ m: ActivityMessage) -> RenderedMessage {
    let segments = m.segments.map { ActivityMessage.Segment(text: sanitize($0.text), isPrivate: $0.isPrivate) }
    let fileText = sanitize(segments.map(\.text).joined())
    let publicText = segments.map { $0.isPrivate ? "<private>" : $0.text }.joined()
    let privateText = segments.filter(\.isPrivate).map(\.text).joined(separator: " · ")
    return RenderedMessage(fileText: fileText, publicText: publicText, privateText: privateText)
  }

  /// Suspends until all previously enqueued log entries have been persisted to disk.
  func flush() async {
    await withCheckedContinuation { c in send(.flush(c)) }
  }

  /// Flushes pending log entries, bounded by a specified timeout duration to avoid indefinite suspension.
  func flush(timeout: Duration) async {
    let waiter = Locked<CheckedContinuation<Void, Never>?>(nil)
    let resumeOnce: @Sendable () -> Void = {
      let c = waiter.withLock { c in
        defer { c = nil }
        return c
      }
      c?.resume()
    }
    await withCheckedContinuation { c in
      waiter.withLock { $0 = c }
      Task { await self.flush(); resumeOnce() }
      Task { try? await Task.sleep(for: timeout); resumeOnce() }
    }
  }

  /// Retrieves the complete entry tree and associated late completions for a given action ID in chronological order.
  func entries(tree id: ActionID) async -> [ActivityEntry] {
    await withCheckedContinuation { c in send(.entriesTree(id, c)) }
  }

  /// Retrieves entries subsequent to a specified sequence counter along with their assigned sequence positions.
  func entries(after sequence: Int) async -> [(Int, ActivityEntry)] {
    await withCheckedContinuation { c in send(.entriesAfter(sequence, c)) }
  }

  /// Retrieves the initiation entries of actions that remained open at startup for reconciliation.
  func openActionsAtLaunch() async -> [ActivityEntry] {
    await withCheckedContinuation { c in send(.openActionsAtLaunch(c)) }
  }

  /// Retrieves indexed action summaries for diagnostic queries.
  func actionRecords() async -> [ActionRecord] {
    await withCheckedContinuation { c in send(.actionRecords(c)) }
  }

  /// Returns the current log sequence position and identifiers for the most recent action and terminal error.
  func status() async -> ActivityLogStatus {
    await withCheckedContinuation { c in send(.status(c)) }
  }

  /// Clears persisted activity history while preserving open actions, recording a boundary clear event.
  func clear() async {
    await withCheckedContinuation { c in
      let event = state.withLock { s in
        let event = ActivityLogEvent.clear(id: Self.takeID(&s), timestamp: clock(), c)
        return Self.isTerminated(continuation.yield(event)) ? event : nil
      }
      event?.answerUndelivered()
    }
  }

  /// Returns a coalesced asynchronous stream of status updates, delivering the latest state after writes.
  func changes() -> AsyncStream<ActivityLogStatus> {
    let (stream, c) = AsyncStream<ActivityLogStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
    send(.subscribe(c))
    return stream
  }

  /// Enqueues a control event, immediately answering continuations if the underlying stream has terminated.
  private func send(_ event: ActivityLogEvent) {
    let undelivered = state.withLock { _ in Self.isTerminated(continuation.yield(event)) }
    if undelivered { event.answerUndelivered() }
  }

  private static func isTerminated(_ result: AsyncStream<ActivityLogEvent>.Continuation.YieldResult) -> Bool {
    if case .terminated = result { return true }
    return false
  }

  /// Advances the sequence counter and generates the next non-zero action identifier.
  private static func takeID(_ s: inout State) -> ActionID {
    if s.nextCounter == 0 { s.nextCounter = 1 }
    let id = actionID(counter: s.nextCounter)
    s.nextCounter &+= 1
    return id
  }

  /// Prepares the log file prior to storage initialization, truncating partial trailing lines and
  /// extracting the latest action counter to prevent identifier collision across process lifecycles.
  static func prepareFile(_ url: URL) -> UInt16 {
    guard let handle = try? FileHandle(forUpdating: url) else { return 0 }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size > 0 else { return 0 }

    // Truncate incomplete trailing writes back to the nearest newline delimiter.
    var window: UInt64 = 64 * 1024
    var end = size
    while true {
      let start = end > window ? end - window : 0
      try? handle.seek(toOffset: start)
      let chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()
      if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
        let keep = start + UInt64(lastNewline - chunk.startIndex) + 1
        if keep < size { try? handle.truncate(atOffset: keep) }
        end = keep
        break
      }
      if start == 0 {
        try? handle.truncate(atOffset: 0)
        return 0
      }
      window *= 2
    }

    // Scan backward to locate the latest action initiation entry and recover the sequence counter.
    window = 64 * 1024
    let decoder = JSONDecoder()
    while true {
      let start = end > window ? end - window : 0
      try? handle.seek(toOffset: start)
      let chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()
      var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
      if start > 0 { lines = Array(lines.dropFirst()) }
      for line in lines.reversed() {
        if let e = try? decoder.decode(ActivityEntry.self, from: Data(line)), e.kind == .begin,
          let counter = counter(of: e.actionID)
        {
          return counter &+ 1
        }
      }
      if start == 0 { return 0 }
      window *= 2
    }
  }

  /// Mirrors activity entries into unified system logging categories with privacy boundaries enforced.
  static let osLogMirror: @Sendable (ActivityEntry, String, String) -> Void = { entry, publicText, privateText in
    let logger = category(for: entry.name)
    var publicEntry = entry
    publicEntry.message = publicText
    let line = "[\(entry.name) \(entry.actionID)] \(ActivityLogFormatter.body(publicEntry))"
    if privateText.isEmpty {
      logger.log("\(line, privacy: .public)")
    } else {
      logger.log("\(line, privacy: .public) · \(privateText, privacy: .private)")
    }
  }

  /// Maps an operational action name to its corresponding OSLog subsystem category.
  static func categoryName(for name: String) -> String {
    switch name {
    case "Send", "Regenerate", "Retry", "Cancel", "Edit and Resend", "Prepare request", "Parse", "Reconcile",
      "Late completion":
      "pipeline"
    case _ where name.hasPrefix("Attempt"), "Background events", "Models refresh", "Validate key", "Add custom model":
      "transport"
    case "Attach", "Prepare attachment", "Tray change":
      "imaging"
    default:
      "store"
    }
  }

  static func category(for name: String) -> Logger {
    switch categoryName(for: name) {
    case "pipeline": Log.pipeline
    case "transport": Log.transport
    case "imaging": Log.imaging
    default: Log.store
    }
  }
}
