import Foundation
import Observation

/// Presentation model driving developer log viewer sheets across scoped action, error, and full log views.
///
/// Captures a frozen target action scope upon presentation and continuously incorporates subsequent
/// matching entries using monotonic sequence cursors, preventing redundant historical reads.
@Observable @MainActor
final class LogViewerModel {
  /// Category of log inspection presented by the sheet.
  enum Kind: Equatable {
    case lastAction
    case lastError
    case fullLog

    var title: String {
      switch self {
      case .lastAction: "Last Action"
      case .lastError: "Last Error"
      case .fullLog: "Full Log"
      }
    }
  }

  let kind: Kind
  private let log: ActivityLog
  private let timeZone: TimeZone
  private let refreshInterval: Duration
  /// Root action identifier defining the inspection scope, or nil for unrestricted timeline display.
  private(set) var actionID: ActionID?
  private(set) var lines: [String] = []
  private(set) var isInProgress = false
  /// Metric tracking lines added during the most recent incremental update.
  private(set) var appendedCount = 0
  /// Indicates completion of the initial asynchronous log hydration pass.
  private(set) var isLoaded = false

  /// Chronological sequence of activity entries currently loaded into the presentation view.
  @ObservationIgnored private var entries: [ActivityEntry] = []
  /// Set of action identifiers comprising the inspected action hierarchy, including child operations and deferred completions.
  @ObservationIgnored private var included: Set<ActionID> = []
  /// Monotonic sequence cursor tracking the latest ingested log entry.
  @ObservationIgnored private var lastSequence = 0
  /// Background stream observation task.
  @ObservationIgnored private var task: Task<Void, Never>?

  init(kind: Kind, log: ActivityLog, startingAt actionID: ActionID?, timeZone: TimeZone = .current,
       refreshInterval: Duration = .milliseconds(250)) {
    self.kind = kind
    self.log = log
    self.actionID = kind == .fullLog ? nil : actionID
    self.timeZone = timeZone
    self.refreshInterval = refreshInterval
  }

  /// Actor-isolated deinitializer cancelling background log observation tasks.
  isolated deinit { task?.cancel() }

  var title: String { kind.title }
  var text: String { lines.joined(separator: "\n") }
  var isEmpty: Bool { entries.isEmpty }

  /// Loads historical log entries and begins background update observation.
  func open() async {
    // Perform initial historical fetch.
    // Subsequent stream notifications will capture concurrent entries.
    let all = await log.entries(after: 0)
    lastSequence = all.last?.0 ?? 0
    let fileEntries = all.map(\.1)
    if let id = actionID {
      // Isolate target action hierarchy, including nested sub-actions and late completions.
      let view = ActivityLogQuery.tree(id, in: fileEntries)
      entries = view.entries
      included = Set(view.entries.map(\.actionID)).union([id])
    } else if kind == .fullLog {
      entries = fileEntries
    }
    render()
    isLoaded = true
    startFollowing()
  }

  /// Terminates background log stream observation.
  func close() {
    task?.cancel()
    task = nil
  }

  /// Sequential task chain coordinating serialized execution of asynchronous log refresh passes.
  @ObservationIgnored private var refreshChain: Task<Void, Never>?

  /// Fetches new log entries beyond the current sequence cursor and appends matching records.
  /// Refreshes serialize sequentially to eliminate concurrent duplication hazards.
  func refresh() async {
    let previous = refreshChain
    let next = Task { [weak self] in
      await previous?.value
      await self?.refreshNow()
    }
    refreshChain = next
    await next.value
  }

  /// Executes a single serialized entry refresh cycle.
  private func refreshNow() async {
    let newer = await log.entries(after: lastSequence)
    guard let last = newer.last?.0 else { return }
    // Advance cursor unconditionally to avoid reprocessing irrelevant intervening entries.
    lastSequence = last
    var added: [ActivityEntry] = []
    for (_, e) in newer {
      switch kind {
      case .fullLog:
        added.append(e)
      case .lastAction, .lastError:
        guard let root = actionID else { continue }
        // Match direct descendants, known sub-actions, or related deferred completion beginnings.
        if included.contains(e.actionID) || e.parentID.map(included.contains) == true
          || (e.kind == .begin && e.relatedID == root && e.parentID == nil)
        {
          included.insert(e.actionID)
          added.append(e)
        }
      }
    }
    guard !added.isEmpty else { return }
    let before = lines.count
    entries += added
    render()
    appendedCount = max(0, lines.count - before)
  }

  /// Formats loaded activity entries into presentable textual lines.
  private func render() {
    let view: ActivityView
    if let id = actionID {
      view = ActivityLogQuery.tree(id, in: entries)
    } else {
      view = ActivityLogQuery.all(entries)
    }
    isInProgress = actionID != nil && view.isInProgress
    lines = entries.isEmpty ? [ActivityLogFormatter.emptyText] : ActivityLogFormatter.lines(view, timeZone: timeZone)
  }

  /// Initiates throttled observation of log change events, coalescing rapid writes within `refreshInterval`.
  private func startFollowing() {
    guard task == nil else { return }
    let stream = log.changes()
    let interval = refreshInterval
    task = Task { [weak self] in
      var last = ContinuousClock.now - interval
      for await _ in stream {
        let wait = interval - (ContinuousClock.now - last)
        if wait > .zero { try? await Task.sleep(for: wait) }
        guard let self, !Task.isCancelled else { return }
        await self.refresh()
        last = ContinuousClock.now
      }
    }
  }

  /// Shareable file representation formatted with ISO-style timestamps.
  var shareFile: LogTextFile { LogTextFile(text: text, date: Date(), timeZone: timeZone) }
}
