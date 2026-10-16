import Foundation
import Observation

/// One open log sheet (D§3.10). It fixes the action it shows when it opens, then appends only
/// newer entries that belong to it (all of them, for Full Log); it never re-runs the selection.
/// Opening, copying and sharing are not logged.
@Observable @MainActor
final class LogViewerModel {
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
  /// Lines added by the latest refresh (for `LogTextView` to append).
  private(set) var appendedCount = 0
  private(set) var isLoaded = false

  @ObservationIgnored private var entries: [ActivityEntry] = []
  @ObservationIgnored private var included: Set<ActionID> = []
  @ObservationIgnored private var lastSequence = 0
  @ObservationIgnored private var task: Task<Void, Never>?

  init(kind: Kind, log: ActivityLog, startingAt actionID: ActionID?, timeZone: TimeZone = .current,
       refreshInterval: Duration = .milliseconds(250)) {
    self.kind = kind
    self.log = log
    self.actionID = kind == .fullLog ? nil : actionID
    self.timeZone = timeZone
    self.refreshInterval = refreshInterval
  }

  isolated deinit { task?.cancel() }

  var title: String { kind.title }
  var text: String { lines.joined(separator: "\n") }
  var isEmpty: Bool { entries.isEmpty }

  /// Loads the view once, then follows the log while open.
  func open() async {
    let all = await log.entries(after: 0)
    lastSequence = all.last?.0 ?? 0
    let fileEntries = all.map(\.1)
    if let id = actionID {
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

  func close() {
    task?.cancel()
    task = nil
  }

  @ObservationIgnored private var refreshChain: Task<Void, Never>?

  /// Fetches entries newer than the last seen sequence and appends the ones that belong.
  /// Refreshes run one after another, so overlapping calls never append an entry twice.
  func refresh() async {
    let previous = refreshChain
    let next = Task { [weak self] in
      await previous?.value
      await self?.refreshNow()
    }
    refreshChain = next
    await next.value
  }

  private func refreshNow() async {
    let newer = await log.entries(after: lastSequence)
    guard let last = newer.last?.0 else { return }
    lastSequence = last
    var added: [ActivityEntry] = []
    for (_, e) in newer {
      switch kind {
      case .fullLog:
        added.append(e)
      case .lastAction, .lastError:
        guard let root = actionID else { continue }
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

  /// The share file, named like `ImageGen-log-2026-10-16-1402.txt`.
  var shareFile: LogTextFile { LogTextFile(text: text, date: Date(), timeZone: timeZone) }
}
