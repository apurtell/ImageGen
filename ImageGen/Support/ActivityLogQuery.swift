import Foundation

/// One action in the store's index (D§4.13): about 100 bytes, no entries.
/// `ActivityLogStore` keeps one for each action in the file and updates it with each entry it writes.
struct ActionRecord: Sendable, Equatable {
  var id: ActionID
  var name: String
  var origin: ActivityOrigin?
  var parentID: ActionID?
  /// true until the action's Result is written.
  var isOpen: Bool
  var outcome: ActivityOutcome?
  /// Late completion only: the action it completes.
  var relatedID: ActionID?
  /// The action's first entry still in the file.
  var firstSequence: Int
  /// Its byte offset: reads of the action's tree start here.
  var firstOffset: UInt64
  /// nil when the begin was rotated out.
  var beginSequence: Int?
  var resultSequence: Int?
}

/// What a log viewer shows.
struct ActivityView: Sendable, Equatable {
  var entries: [ActivityEntry]
  /// The shown action has no result yet.
  var isInProgress: Bool
  /// The shown action's begin is no longer in the file.
  var hasRotatedOutStart: Bool
  /// Late completions of the shown action (and their sub-actions), shown after "(completed later)".
  var lateCompletionIDs: Set<ActionID> = []
  /// Full Log: date lines from the start.
  var isFullLog = false
}

/// Picks and shapes what the viewer shows (D§3.10). Pure.
///
/// An `enum` with no cases is a namespace for static functions. `lastAction` and `lastError` work
/// on the index's records. The store calls them for each status, after every write, so keep them
/// linear in the number of records. `tree` and `all` shape entries read from the file.
enum ActivityLogQuery {
  /// The outcomes that put an action in Last Error (D§4.13 Outcomes).
  static let errorOutcomes: Set<ActivityOutcome> = [.failed, .refused, .interrupted]

  /// The most recently begun top-level action the user started; if there's none, the newest of
  /// any origin. Late completions are system actions, so they're never picked here.
  /// "Begun" is judged by `firstSequence`, the action's first entry still in the file.
  static func lastAction(_ actions: [ActionRecord]) -> ActionID? {
    let top = actions.filter { $0.parentID == nil }
    let newest = { (rs: [ActionRecord]) in rs.max { $0.firstSequence < $1.firstSequence }?.id }
    return newest(top.filter { $0.origin == .user }) ?? newest(top)
  }

  /// The top-level action whose result is the newest with outcome failed, refused or interrupted.
  /// An action is judged by its newest Late completion: one that succeeded clears it, one that
  /// failed keeps it (and makes it as recent as that result).
  static func lastError(_ actions: [ActionRecord]) -> ActionID? {
    // First pass: the newest Late completion of each original action.
    var latestCompletion: [ActionID: ActionRecord] = [:]
    for r in actions where r.parentID == nil {
      guard let original = r.relatedID else { continue }
      if let current = latestCompletion[original], current.firstSequence > r.firstSequence { continue }
      latestCompletion[original] = r
    }
    // Second pass: originals only. A Late completion with a result replaces the original's outcome.
    // An open Late completion has no outcome yet, so the original's own outcome decides.
    var best: (id: ActionID, sequence: Int)?
    for r in actions where r.parentID == nil && r.relatedID == nil {
      guard let outcome = r.outcome, var sequence = r.resultSequence else { continue }
      var isError = errorOutcomes.contains(outcome)
      if let late = latestCompletion[r.id], let lateOutcome = late.outcome, let lateSequence = late.resultSequence {
        isError = errorOutcomes.contains(lateOutcome)
        sequence = max(sequence, lateSequence)
      }
      guard isError else { continue }
      if best == nil || sequence > best!.sequence { best = (r.id, sequence) }
    }
    return best?.id
  }

  /// The action, all its sub-actions and its Late completions, from entries in file order. The
  /// action's own lines come first, then each Late completion's.
  static func tree(_ id: ActionID, in entries: [ActivityEntry]) -> ActivityView {
    var own: Set<ActionID> = [id]
    var late: Set<ActionID> = []
    var ownEntries: [ActivityEntry] = []
    var lateEntries: [ActivityEntry] = []
    // One pass in file order is enough: a sub-action begins after its parent's first entry, so the
    // parent is already in `own` or `late` when its children appear.
    for e in entries {
      if own.contains(e.actionID) || e.parentID.map(own.contains) == true {
        own.insert(e.actionID)
        ownEntries.append(e)
      } else if late.contains(e.actionID) || e.parentID.map(late.contains) == true
        || (e.kind == .begin && e.relatedID == id && e.parentID == nil)
      {
        late.insert(e.actionID)
        lateEntries.append(e)
      }
    }
    let root = ownEntries.filter { $0.actionID == id }
    return ActivityView(
      entries: ownEntries + lateEntries,
      isInProgress: !root.contains { $0.kind == .result },
      hasRotatedOutStart: root.first.map { $0.kind != .begin } ?? false,
      lateCompletionIDs: late)
  }

  /// Every entry, in file order.
  static func all(_ entries: [ActivityEntry]) -> ActivityView {
    ActivityView(
      entries: entries, isInProgress: false, hasRotatedOutStart: entries.first.map { $0.kind != .begin } ?? false,
      isFullLog: true)
  }
}
