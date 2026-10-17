import Foundation
import Observation

/// One open log sheet (D§3.10). It fixes the action it shows when it opens, then appends only
/// newer entries that belong to it (all of them, for Full Log); it never re-runs the selection.
/// Opening, copying and sharing are not logged.
///
/// `DeveloperMenu` creates one for each sheet; `LogViewerSheet` owns it and calls `open()` and
/// `close()`. The model reads from `ActivityLog`, whose store is an actor, so each read is an `await`.
/// It runs on the main actor. Two kinds of work can overlap: the follow task (one per model, started
/// by `open()`) and any `refresh()` call. Refreshes are chained one after another, so only one reads
/// and appends at a time. The model fetches by sequence number: each refresh asks only for entries
/// after `lastSequence`, so an entry is never fetched twice and the full log is never read again.
@Observable @MainActor
final class LogViewerModel {
  /// Which menu item opened the sheet.
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
  /// The action this sheet shows (nil for Full Log, or when the log has none).
  private(set) var actionID: ActionID?
  private(set) var lines: [String] = []
  private(set) var isInProgress = false
  /// Lines added by the latest refresh (for `LogTextView` to append). `LogTextView` itself finds
  /// the new tail by comparing texts; the tests read this count.
  private(set) var appendedCount = 0
  /// False until the first load ends; the sheet shows a spinner until then.
  private(set) var isLoaded = false

  // `@ObservationIgnored`: views do not read these directly, so changing them does not redraw.
  /// The entries this view shows, in the order they were fetched.
  @ObservationIgnored private var entries: [ActivityEntry] = []
  /// The shown action and every sub-action and Late completion seen so far. A new entry belongs to
  /// the view when its action or its parent is in this set.
  @ObservationIgnored private var included: Set<ActionID> = []
  /// The sequence number of the newest entry fetched. The log's sequence numbers only grow, also
  /// across Clear Log, so "after `lastSequence`" never skips or repeats an entry.
  @ObservationIgnored private var lastSequence = 0
  /// The follow task. Cancelled by `close()` and when the model goes away.
  @ObservationIgnored private var task: Task<Void, Never>?

  init(kind: Kind, log: ActivityLog, startingAt actionID: ActionID?, timeZone: TimeZone = .current,
       refreshInterval: Duration = .milliseconds(250)) {
    self.kind = kind
    self.log = log
    self.actionID = kind == .fullLog ? nil : actionID
    self.timeZone = timeZone
    self.refreshInterval = refreshInterval
  }

  /// `isolated deinit` runs on the main actor, where `task` lives.
  isolated deinit { task?.cancel() }

  var title: String { kind.title }
  var text: String { lines.joined(separator: "\n") }
  var isEmpty: Bool { entries.isEmpty }

  /// Loads the view once, then follows the log while open.
  /// Called by the sheet's `.task`. SwiftUI cancels that task when the sheet closes, but the log
  /// reads do not check cancellation, so a load can end after `close()`. The follow task that it
  /// then starts ends when the model goes away (`deinit`).
  func open() async {
    // One full read. Entries written after this read and before the follow task subscribes are not
    // lost: the stream sends the current status at once, and that first refresh fetches them.
    let all = await log.entries(after: 0)
    lastSequence = all.last?.0 ?? 0
    let fileEntries = all.map(\.1)
    if let id = actionID {
      // The action, its sub-actions and its Late completions (the same rule as the store's tree).
      let view = ActivityLogQuery.tree(id, in: fileEntries)
      entries = view.entries
      included = Set(view.entries.map(\.actionID)).union([id])
    } else if kind == .fullLog {
      entries = fileEntries
    }
    // Otherwise (Last Action or Last Error with no action in the log) `entries` stays empty, and
    // the view shows "No log entries".
    render()
    isLoaded = true
    startFollowing()
  }

  /// Stops following. The sheet calls this from `.onDisappear`.
  func close() {
    task?.cancel()
    task = nil
  }

  /// The newest refresh. Each new refresh waits for this one first, so refreshes form a queue.
  @ObservationIgnored private var refreshChain: Task<Void, Never>?

  /// Fetches entries newer than the last seen sequence and appends the ones that belong.
  /// Refreshes run one after another, so overlapping calls never append an entry twice.
  /// Without the chain, two calls could both read `lastSequence` before either `await` returns, and
  /// both would append the same entries (see the primer, *async and await: suspension points*).
  func refresh() async {
    // These three lines run with no `await` between them, so no other refresh can run in between
    // and take the same place in the queue.
    let previous = refreshChain
    let next = Task { [weak self] in
      await previous?.value
      await self?.refreshNow()
    }
    refreshChain = next
    await next.value
  }

  /// One refresh. Only the chain in `refresh()` calls it, so it never overlaps another call.
  private func refreshNow() async {
    let newer = await log.entries(after: lastSequence)
    guard let last = newer.last?.0 else { return }
    // Advanced even when none of the new entries belongs to this view, so they are not read again.
    lastSequence = last
    var added: [ActivityEntry] = []
    for (_, e) in newer {
      switch kind {
      case .fullLog:
        added.append(e)
      case .lastAction, .lastError:
        guard let root = actionID else { continue }
        // The same three cases as `ActivityLogQuery.tree`: an entry of a known action, a new
        // sub-action of a known action, or the Begin of a Late completion of the shown action.
        // File order guarantees a parent's Begin comes before its children.
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

  /// Formats all of `entries` again. The text is recomputed whole; `LogTextView` then appends only
  /// the part that is new.
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

  /// Starts the follow task: a refresh after each change to the log, at most one per
  /// `refreshInterval`, so a burst of writes costs one read.
  private func startFollowing() {
    guard task == nil else { return }
    // The stream's values are only a signal that the log changed; the refresh reads the entries.
    // It keeps only the newest value, so changes during the wait below collapse into one.
    let stream = log.changes()
    // Captured as a local, so the task does not need `self` for it.
    let interval = refreshInterval
    // `Task {}` inherits the main actor. `[weak self]`: the task does not keep the model alive; the
    // model's `deinit` cancels it.
    task = Task { [weak self] in
      var last = ContinuousClock.now - interval
      for await _ in stream {
        let wait = interval - (ContinuousClock.now - last)
        if wait > .zero { try? await Task.sleep(for: wait) }  // try?: a cancelled sleep ends early; the check below then stops.
        // `guard let self` holds the model only for this pass of the loop. The cancellation check
        // stops a refresh after `close()`, which can come during the sleep.
        guard let self, !Task.isCancelled else { return }
        await self.refresh()
        last = ContinuousClock.now
      }
    }
  }

  /// The share file, named like `ImageGen-log-2026-10-16-1402.txt`.
  var shareFile: LogTextFile { LogTextFile(text: text, date: Date(), timeZone: timeZone) }
}
