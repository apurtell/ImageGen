import Foundation
import OSLog
import Synchronization

/// A log message built by string interpolation. `\(private: x)` marks a segment private for the
/// OSLog mirror; the file holds the full text (D§4.13).
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

/// A rendered message: the file text and the OSLog mirror's public and private parts.
struct RenderedMessage: Sendable {
  var fileText: String
  /// The line with `<private>` in place of each private segment.
  var publicText: String
  /// The private segments, joined with ` · `.
  var privateText: String

  static func plain(_ text: String) -> RenderedMessage {
    RenderedMessage(fileText: text, publicText: text, privateText: "")
  }
}

/// Messages from the facade to the store, in one ordered stream (D§4.13).
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
}

/// The activity log's facade (D§4.13): synchronous, callable from any isolation, never awaits.
/// Each call sanitizes and renders its message before taking the lock; under the lock it only
/// takes an ID, stamps the time and yields into the ordered stream, so file order is lock order.
final class ActivityLog: Sendable {
  /// IDs are a 16-bit counter times this odd constant, so consecutive IDs look different.
  static let idMultiplier: UInt16 = 0x9E37
  static let idInverse: UInt16 = {
    // Newton's iteration for the inverse of an odd number mod 2^16.
    var x = idMultiplier
    for _ in 0..<5 { x = x &* (2 &- idMultiplier &* x) }
    return x
  }()

  static func actionID(counter: UInt16) -> ActionID {
    ActionID(raw: String(format: "%04x", counter &* idMultiplier))
  }

  static func counter(of id: ActionID) -> UInt16? {
    UInt16(id.raw, radix: 16).map { $0 &* idInverse }
  }

  private struct State {
    var nextCounter: UInt16
  }

  private let state: Mutex<State>
  private let continuation: AsyncStream<ActivityLogEvent>.Continuation
  private let sanitize: @Sendable (String) -> String
  private let clock: @Sendable () -> Date
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

  /// Ends the stream and waits until the store has written everything and closed the file.
  /// Calls after this are dropped.
  func close() async {
    state.withLock { _ in continuation.finish() }
    await storeTask.value
  }

  // MARK: Entries

  /// Begins a top-level action.
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
  @discardableResult
  func beginLateCompletion(of original: ActionID, _ m: ActivityMessage) -> ActionID {
    begin("Late completion", parent: nil, origin: .system, relatedID: original, m)
  }

  func step(_ id: ActionID, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      let entry = ActivityEntry(timestamp: clock(), actionID: id, name: "", kind: .step, message: rendered.fileText)
      continuation.yield(.entry(entry, rendered))
    }
  }

  func result(_ id: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      let entry = ActivityEntry(
        timestamp: clock(), actionID: id, name: "", kind: .result, outcome: outcome, message: rendered.fileText)
      continuation.yield(.entry(entry, rendered))
    }
  }

  /// Ends the newest open sub-action named `name` under `parent`; the store resolves it, for a
  /// sub-action opened by an earlier process.
  func result(ofOpenChild name: String, of parent: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      _ = continuation.yield(.resultOfOpenChild(name: name, parent: parent, outcome: outcome, timestamp: clock(), rendered))
    }
  }

  private func begin(
    _ name: String, parent: ActionID?, origin: ActivityOrigin?, relatedID: ActionID?, _ m: ActivityMessage
  ) -> ActionID {
    let rendered = render(m)
    return state.withLock { s in
      let id = Self.actionID(counter: s.nextCounter)
      s.nextCounter &+= 1
      let entry = ActivityEntry(
        timestamp: clock(), actionID: id, parentID: parent, name: name, kind: .begin, origin: origin,
        relatedID: relatedID, message: rendered.fileText)
      continuation.yield(.entry(entry, rendered))
      return id
    }
  }

  private func render(_ m: ActivityMessage) -> RenderedMessage {
    let segments = m.segments.map { ActivityMessage.Segment(text: sanitize($0.text), isPrivate: $0.isPrivate) }
    // A final pass over the whole line catches anything split across segments.
    let fileText = sanitize(segments.map(\.text).joined())
    let publicText = segments.map { $0.isPrivate ? "<private>" : $0.text }.joined()
    let privateText = segments.filter(\.isPrivate).map(\.text).joined(separator: " · ")
    return RenderedMessage(fileText: fileText, publicText: publicText, privateText: privateText)
  }

  // MARK: Control messages (answered by the store in stream order)

  /// Returns once every earlier call is written to the file.
  func flush() async {
    await withCheckedContinuation { c in send(.flush(c)) }
  }

  /// Flushes, giving up after `timeout` so a stuck write can't hold up the caller.
  func flush(timeout: Duration) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.flush() }
      group.addTask { try? await Task.sleep(for: timeout) }
      await group.next()
      group.cancelAll()
    }
  }

  /// That action's tree and its Late completions, in file order.
  func entries(tree id: ActionID) async -> [ActivityEntry] {
    await withCheckedContinuation { c in send(.entriesTree(id, c)) }
  }

  /// Entries newer than `sequence`, with their sequence numbers; 0 = all.
  func entries(after sequence: Int) async -> [(Int, ActivityEntry)] {
    await withCheckedContinuation { c in send(.entriesAfter(sequence, c)) }
  }

  /// The begins of actions that were open when the file was loaded and are still open (M4's Reconciler).
  func openActionsAtLaunch() async -> [ActivityEntry] {
    await withCheckedContinuation { c in send(.openActionsAtLaunch(c)) }
  }

  /// The index's action records, for queries.
  func actionRecords() async -> [ActionRecord] {
    await withCheckedContinuation { c in send(.actionRecords(c)) }
  }

  func status() async -> ActivityLogStatus {
    await withCheckedContinuation { c in send(.status(c)) }
  }

  /// Keeps the begins of open actions, then writes the Log cleared action.
  func clear() async {
    await withCheckedContinuation { c in
      state.withLock { s in
        let id = Self.actionID(counter: s.nextCounter)
        s.nextCounter &+= 1
        continuation.yield(.clear(id: id, timestamp: clock(), c))
      }
    }
  }

  /// Coalesced: the current status at once, then one value after each write.
  func changes() -> AsyncStream<ActivityLogStatus> {
    let (stream, c) = AsyncStream<ActivityLogStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
    send(.subscribe(c))
    return stream
  }

  private func send(_ event: ActivityLogEvent) {
    state.withLock { _ in _ = continuation.yield(event) }
  }

  // MARK: Startup

  /// One bounded pass over the file's tail: cuts off a partial last line, and returns the counter
  /// after the newest begin's (0 with no file).
  static func prepareFile(_ url: URL) -> UInt16 {
    guard let handle = try? FileHandle(forUpdating: url) else { return 0 }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd(), size > 0 else { return 0 }

    // Truncate back to the last newline.
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

    // Find the newest begin, reading further back only if the tail has none.
    window = 64 * 1024
    let decoder = JSONDecoder()
    while true {
      let start = end > window ? end - window : 0
      try? handle.seek(toOffset: start)
      let chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()
      var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
      if start > 0 { lines = Array(lines.dropFirst()) }  // possibly cut
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

  // MARK: OSLog mirror

  static let osLogMirror: @Sendable (ActivityEntry, String, String) -> Void = { entry, publicText, privateText in
    let logger = category(for: entry.name)
    let head = "[\(entry.name) \(entry.actionID)] \(entry.kind.rawValue)\(entry.outcome.map { " \($0.rawValue)" } ?? "")"
    if privateText.isEmpty {
      logger.log("\(head, privacy: .public): \(publicText, privacy: .public)")
    } else {
      logger.log("\(head, privacy: .public): \(publicText, privacy: .public) · \(privateText, privacy: .private)")
    }
  }

  /// The OSLog category for an action name (D§4.13).
  static func categoryName(for name: String) -> String {
    switch name {
    case "Send", "Regenerate", "Retry", "Cancel", "Edit & Resend", "Prepare request", "Parse", "Reconcile",
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
