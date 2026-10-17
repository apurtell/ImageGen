import Foundation

/// Compact in-memory metadata descriptor indexing an individual action lifecycle within `ActivityLogStore`.
struct ActionRecord: Sendable, Equatable {
  var id: ActionID
  var name: String
  var origin: ActivityOrigin?
  var parentID: ActionID?
  /// Indicates whether the action is currently awaiting a terminal result entry.
  var isOpen: Bool
  var outcome: ActivityOutcome?
  /// Identifies the original action completed by this record, when applicable.
  var relatedID: ActionID?
  /// Sequence number of the earliest surviving entry for this action.
  var firstSequence: Int
  /// File byte offset corresponding to the initial recorded entry.
  var firstOffset: UInt64
  /// Sequence number of the action's begin record, or nil if evicted by log rotation.
  var beginSequence: Int?
  var resultSequence: Int?
}

/// Presentation model encapsulating filtered log entries and structural metadata for the log viewer interface.
struct ActivityView: Sendable, Equatable {
  var entries: [ActivityEntry]
  /// Indicates whether the primary action remains active without a recorded outcome.
  var isInProgress: Bool
  /// Indicates whether the initiation entry was pruned by file rotation.
  var hasRotatedOutStart: Bool
  /// Set of action identifiers representing late completions and their descendant hierarchy.
  var lateCompletionIDs: Set<ActionID> = []
  /// Designates whether this view represents an unconstrained historical log.
  var isFullLog = false
}

/// Query engine evaluating action indices and shaping raw log entries for diagnostic views and inspection.
enum ActivityLogQuery {
  /// Outcomes qualifying an action for error tracking and presentation.
  static let errorOutcomes: Set<ActivityOutcome> = [.failed, .refused, .interrupted]

  /// Resolves the most recently initiated top-level action, prioritizing user-initiated actions.
  static func lastAction(_ actions: [ActionRecord]) -> ActionID? {
    let top = actions.filter { $0.parentID == nil }
    let newest = { (rs: [ActionRecord]) in rs.max { $0.firstSequence < $1.firstSequence }?.id }
    return newest(top.filter { $0.origin == .user }) ?? newest(top)
  }

  /// Resolves the most recent top-level action yielding a failed, refused, or interrupted outcome,
  /// accounting for overriding late completion dispositions.
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

  /// Constructs an `ActivityView` hierarchy spanning an action, its descendant sub-actions, and linked late completions.
  static func tree(_ id: ActionID, in entries: [ActivityEntry]) -> ActivityView {
    var own: Set<ActionID> = [id]
    var late: Set<ActionID> = []
    var ownEntries: [ActivityEntry] = []
    var lateEntries: [ActivityEntry] = []
    // Single sequential pass resolves hierarchy since parent actions precede child records.
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

  /// Constructs an `ActivityView` containing the complete chronological entry sequence.
  static func all(_ entries: [ActivityEntry]) -> ActivityView {
    ActivityView(
      entries: entries, isInProgress: false, hasRotatedOutStart: entries.first.map { $0.kind != .begin } ?? false,
      isFullLog: true)
  }
}
