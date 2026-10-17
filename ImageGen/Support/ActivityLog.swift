import Foundation
import OSLog
import Synchronization

// The activity log's facade, `ActivityLog`, and the message types it sends to `ActivityLogStore`. The
// design overview is on `ActivityLog` below.

/// A log message built by string interpolation. `\(private: x)` marks a segment private for the
/// OSLog mirror; the file holds the full text (D§4.13).
///
/// `ExpressibleByStringInterpolation` lets a caller pass a literal such as `"prompt \(private: p)"`
/// where an `ActivityMessage` is expected. The compiler turns the literal into calls on
/// `StringInterpolation` below, one for each literal piece and each `\(...)` value.
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

  /// The compiler builds one of these for each interpolated literal. The argument label of a
  /// `\(...)` picks the `appendInterpolation` overload, so `\(private: x)` makes a private segment.
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

    /// Merges a piece into the last segment when both have the same privacy, so a message has the
    /// fewest segments.
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
/// The facade builds it on the caller's thread, before it takes its lock, so the store does no
/// sanitizing.
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
///
/// `entry` and `resultOfOpenChild` are log entries. The other cases are control messages. Each one
/// carries a continuation (see the primer, *Continuations*): the caller waits on it, and the store
/// resumes it when it reaches the message in the stream. So a control message sees every entry sent
/// before it. `subscribe` carries the write end of a status stream instead. Each continuation is
/// resumed exactly once: by the store in `ActivityLogStore.handle`, or, for a message the store never
/// receives, by `answerUndelivered`.
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

  /// Answers a control message the store will never see (the stream has ended): every caller
  /// waiting on one is resumed at once, with an empty answer, instead of waiting forever.
  /// The facade calls it after `yield` reports `.terminated`, outside its lock. Entries need no answer.
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

/// The activity log's facade (D§4.13): synchronous, callable from any isolation, never awaits.
/// Each call sanitizes and renders its message before taking the lock; under the lock it only
/// takes an ID, stamps the time and yields into the ordered stream, so file order is lock order.
///
/// Every layer logs through this one object, which `AppEnvironment` creates. Because no call awaits,
/// code that can't `await` (a network callback, a `deinit`) can log too. The class is `Sendable`
/// without `@unchecked`: its only mutable state, the ID counter, is in a `Mutex` (see the primer,
/// *Locks*). Rendering runs outside the lock, because the sanitizer's regex pass over a long prompt is
/// the costly part. Nothing else happens under the lock: no file I/O and no OSLog call. Since the
/// yield is under the lock, timestamps never go backwards in the file.
///
/// The other end of the stream is `ActivityLogStore`, an actor that is the stream's only consumer and
/// the file's only writer. Queries (`flush()`, `entries`, `clear()`, `status()`) travel in the same
/// stream as control messages, so each one sees every entry logged before it.
final class ActivityLog: Sendable {
  /// IDs are a 16-bit counter times this odd constant, so consecutive IDs look different.
  /// An odd number has an inverse mod 2^16, so `counter(of:)` can undo the multiplication.
  static let idMultiplier: UInt16 = 0x9E37
  /// The inverse of `idMultiplier` mod 2^16. `&*` and `&-` wrap on overflow; plain `*` and `-` stop
  /// the app on overflow in Swift.
  static let idInverse: UInt16 = {
    // Newton's iteration for the inverse of an odd number mod 2^16.
    // Each step doubles the number of correct low bits, so five steps are more than enough.
    var x = idMultiplier
    for _ in 0..<5 { x = x &* (2 &- idMultiplier &* x) }
    return x
  }()

  static func actionID(counter: UInt16) -> ActionID {
    ActionID(raw: String(format: "%04x", counter &* idMultiplier))
  }

  /// Undoes `actionID(counter:)`; nil when the ID isn't hex. `prepareFile` uses it to continue the
  /// counter from the file.
  static func counter(of id: ActionID) -> UInt16? {
    UInt16(id.raw, radix: 16).map { $0 &* idInverse }
  }

  private struct State {
    var nextCounter: UInt16
  }

  /// Protects the counter. Every yield into `continuation` also happens under this lock, so the
  /// stream (and so the file) has the same order as the lock.
  private let state: Mutex<State>
  /// The write end of the stream to the store (see the primer, *AsyncStream*). The stream is
  /// unbounded, so `yield` never blocks the caller.
  private let continuation: AsyncStream<ActivityLogEvent>.Continuation
  /// `Redactor.forLog(secrets:)`, injected by `AppEnvironment` (D§4.13 Redaction).
  private let sanitize: @Sendable (String) -> String
  /// Injected, so tests control the timestamps.
  private let clock: @Sendable () -> Date
  /// Runs the store's loop; `close()` waits for it. Nothing cancels it: a cancelled `for await` loop
  /// stops early and would leave queued control messages unanswered.
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
    // Synchronous, before the store starts: it repairs a cut last line before the store loads the
    // file, and it seeds the counter.
    let seed = Self.prepareFile(fileURL)
    state = Mutex(State(nextCounter: seed))
    let (stream, continuation) = AsyncStream<ActivityLogEvent>.makeStream()
    self.continuation = continuation
    let store = ActivityLogStore(fileURL: fileURL, mirror: mirror, limits: limits)
    // `Task.detached` takes neither the caller's actor nor its priority; the store runs at utility
    // priority. The task holds the store, not `self`, so the facade can still be released.
    storeTask = Task.detached(priority: .utility) { await store.run(stream) }
  }

  /// Runs when the last reference goes. Ending the stream lets the store write what is still
  /// queued, close the file and finish.
  deinit {
    continuation.finish()
  }

  /// Ends the stream and waits until the store has written everything and closed the file.
  /// Calls after this are dropped.
  func close() async {
    // Finishing under the lock puts the end of the stream at one point in lock order: each call is
    // before it (and written) or after it (and dropped, or answered at once).
    state.withLock { _ in continuation.finish() }
    await storeTask.value
  }

  // MARK: Entries

  /// Begins a top-level action. The caller passes the returned ID to `step` and `result`, and must
  /// end the action with exactly one Result (see the primer, *The activity log*).
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

  /// Ends an action. The store keeps exactly one Result for each action: it drops a second one and
  /// reports it under the OSLog `store` category. Sub-actions still open are first closed as
  /// interrupted (the backstop in `ActivityLogStore`).
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
  /// The facade can't resolve it: the sub-action's ID is only in the file and the store's index. Used
  /// for an Attempt after a relaunch (D§4.13 Continuing across processes).
  func result(ofOpenChild name: String, of parent: ActionID, _ outcome: ActivityOutcome, _ m: ActivityMessage) {
    let rendered = render(m)
    state.withLock { _ in
      _ = continuation.yield(.resultOfOpenChild(name: name, parent: parent, outcome: outcome, timestamp: clock(), rendered))
    }
  }

  /// Takes the ID and yields in one locked step, so IDs increase in file order. `prepareFile`
  /// depends on this: the newest begin in the file holds the counter to continue from.
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

  /// Sanitizes and renders on the caller's thread, outside the lock. Each segment is sanitized for
  /// the OSLog mirror, and the joined line again for the file.
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
  /// `withCheckedContinuation` pauses this task until the store resumes `c` (see the primer,
  /// *Continuations*). After `close()` it returns at once. Callers await a flush before the app can
  /// be suspended, and before they store an action ID outside the log (D§4.13 Flushing before
  /// suspension).
  func flush() async {
    await withCheckedContinuation { c in send(.flush(c)) }
  }

  /// Flushes, giving up after `timeout` so a stuck write can't hold up the caller (an expiring
  /// background task must end on time). The flush and a timer race to resume one waiter; the
  /// loser finds it already resumed. (A task group can't do this: it waits for every child before
  /// it returns, and a waiting flush can't be cancelled.)
  ///
  /// `waiter` holds the continuation in a `Locked`. `resumeOnce` takes it out and sets the slot to nil
  /// in one locked step, so exactly one of the two tasks resumes it. The continuation is stored
  /// before either task starts, so neither can find the slot empty too early. Both tasks are
  /// unstructured (`Task { }`): this function doesn't wait for the loser, and the caller's
  /// cancellation doesn't reach them. The loser runs to its end later, which is harmless.
  func flush(timeout: Duration) async {
    let waiter = Locked<CheckedContinuation<Void, Never>?>(nil)
    let resumeOnce: @Sendable () -> Void = {
      let c = waiter.withLock { c in
        defer { c = nil }  // Runs after the value is read for the return: take it, then clear it.
        return c
      }
      c?.resume()
    }
    await withCheckedContinuation { c in
      waiter.withLock { $0 = c }
      Task { await self.flush(); resumeOnce() }
      Task { try? await Task.sleep(for: timeout); resumeOnce() }  // Throws only if cancelled; nothing cancels it.
    }
  }

  /// That action's tree and its Late completions, in file order.
  /// For the viewer's Last Action and Last Error.
  func entries(tree id: ActionID) async -> [ActivityEntry] {
    await withCheckedContinuation { c in send(.entriesTree(id, c)) }
  }

  /// Entries newer than `sequence`, with their sequence numbers; 0 = all.
  /// The viewer's refresh passes the last number it saw. Numbers count from the file's start at load
  /// time, so they are valid only within one process.
  func entries(after sequence: Int) async -> [(Int, ActivityEntry)] {
    await withCheckedContinuation { c in send(.entriesAfter(sequence, c)) }
  }

  /// The begins of actions that were open when the file was loaded and are still open (M4's Reconciler).
  /// The Reconciler closes the ones a previous process left open.
  func openActionsAtLaunch() async -> [ActivityEntry] {
    await withCheckedContinuation { c in send(.openActionsAtLaunch(c)) }
  }

  /// The index's action records, for queries.
  func actionRecords() async -> [ActionRecord] {
    await withCheckedContinuation { c in send(.actionRecords(c)) }
  }

  /// The newest sequence number, and the IDs that Last Action and Last Error would pick.
  func status() async -> ActivityLogStatus {
    await withCheckedContinuation { c in send(.status(c)) }
  }

  /// Keeps the begins of open actions, then writes the Log cleared action.
  func clear() async {
    await withCheckedContinuation { c in
      // Not `send`: like a begin, the ID and the yield share one locked step, so the Log cleared
      // action gets the next ID in order and every earlier entry is written before the clear.
      let event = state.withLock { s in
        let event = ActivityLogEvent.clear(id: Self.takeID(&s), timestamp: clock(), c)
        return Self.isTerminated(continuation.yield(event)) ? event : nil
      }
      // The stream has ended: resume `c` at once, outside the lock.
      event?.answerUndelivered()
    }
  }

  /// Coalesced: the current status at once, then one value after each write.
  /// `bufferingNewest(1)` keeps only the newest unread status, so a slow reader gets the latest value
  /// instead of a backlog. After `close()` the stream ends at once, with no value. Read by
  /// `DeveloperMenuModel` and `LogViewerModel`.
  func changes() -> AsyncStream<ActivityLogStatus> {
    let (stream, c) = AsyncStream<ActivityLogStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
    send(.subscribe(c))
    return stream
  }

  /// Yields a control message. If the stream has ended, answers it at once, so no caller waits
  /// forever. The answer happens outside the lock, which covers only the yield.
  private func send(_ event: ActivityLogEvent) {
    let undelivered = state.withLock { _ in Self.isTerminated(continuation.yield(event)) }
    if undelivered { event.answerUndelivered() }
  }

  /// `if case` tests a value against one enum case.
  private static func isTerminated(_ result: AsyncStream<ActivityLogEvent>.Continuation.YieldResult) -> Bool {
    if case .terminated = result { return true }
    return false
  }

  /// The next action ID. Counter 0 is skipped: its ID, `0000`, is the placeholder for "no action".
  /// `inout` lets it change the locked state in place; callers call it inside `withLock`. `&+=` wraps
  /// 0xFFFF to 0, which the next call then skips.
  private static func takeID(_ s: inout State) -> ActionID {
    if s.nextCounter == 0 { s.nextCounter = 1 }
    let id = actionID(counter: s.nextCounter)
    s.nextCounter &+= 1
    return id
  }

  // MARK: Startup

  /// One bounded pass over the file's tail: cuts off a partial last line, and returns the counter
  /// after the newest begin's (0 with no file).
  ///
  /// Runs once, in `init`, on the caller's thread, before the store task starts. So the store never
  /// reads the partial line, and this process's first entry starts on a line of its own. The counter
  /// is kept only in memory and in the file, not in `UserDefaults`, which saves asynchronously and could
  /// lose increments in a kill. So an ID in the file is never handed out again (D§4.13 Model).
  static func prepareFile(_ url: URL) -> UInt16 {
    guard let handle = try? FileHandle(forUpdating: url) else { return 0 }  // No file yet: start at 0.
    defer { try? handle.close() }  // Nothing is buffered; a close error loses nothing.
    guard let size = try? handle.seekToEnd(), size > 0 else { return 0 }  // Unreadable or empty: start at 0.

    // Truncate back to the last newline.
    // The window doubles until it holds a newline. A file with no newline at all is one partial
    // line, and is emptied.
    var window: UInt64 = 64 * 1024
    var end = size
    while true {
      let start = end > window ? end - window : 0
      try? handle.seek(toOffset: start)  // A failed seek gives a short or empty read below.
      let chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()  // Unreadable: treated as empty.
      if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
        let keep = start + UInt64(lastNewline - chunk.startIndex) + 1
        if keep < size { try? handle.truncate(atOffset: keep) }  // Best effort: at worst one line is lost.
        end = keep
        break
      }
      if start == 0 {
        try? handle.truncate(atOffset: 0)  // Best effort: at worst one line is lost.
        return 0
      }
      window *= 2
    }

    // Find the newest begin, reading further back only if the tail has none.
    // File order is ID order (see `begin`), so the newest begin holds the newest counter.
    window = 64 * 1024
    let decoder = JSONDecoder()
    while true {
      let start = end > window ? end - window : 0
      try? handle.seek(toOffset: start)  // A failed seek gives a short or empty read below.
      let chunk = (try? handle.read(upToCount: Int(end - start))) ?? Data()  // Unreadable: treated as empty.
      var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
      if start > 0 { lines = Array(lines.dropFirst()) }  // possibly cut
      for line in lines.reversed() {
        if let e = try? decoder.decode(ActivityEntry.self, from: Data(line)), e.kind == .begin,  // Bad line: skip.
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

  /// Lines like the viewer's (`[Send a1b2] Result: success in 14.2 s · …`); private segments read
  /// `<private>` in the public text and follow, marked private, after it.
  /// The store calls it after it writes each entry, so the mirror holds exactly the file's entries
  /// (D§4.13 OSLog mirror). OSLog hides a `.private` value unless the device is set up for debugging.
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

  /// The OSLog category for an action name (D§4.13).
  /// An Attempt matches by prefix, because its name carries its number ("Attempt 2").
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
