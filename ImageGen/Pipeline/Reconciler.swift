import Foundation

/// Executes process startup reconciliation following background session restoration. Synchronizes non-terminal
/// database records with active URLSession tasks, reevaluates complete responses saved prior to termination,
/// applies a grace period before marking orphaned requests as interrupted, and resolves unclosed diagnostic log actions.
///
/// Invoked asynchronously during application initialization. All state mutations on generation requests are delegated
/// to `GenerationService` hooks, which enforce per-request serial synchronization.
struct Reconciler: Sendable {
  let store: DataStore
  let transport: any GenerationTransport
  let service: GenerationService
  let files: FileStore
  let log: ActivityLog
  /// Grace duration allotted for late background completions before requests without matching tasks are marked interrupted.
  var grace: Duration = .seconds(5)
  /// Configurable suspension hook utilized to inject immediate completion during testing.
  var sleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

  static let closedReason = "the app was closed before this finished"

  func run() async {
    let started = ContinuousClock.now
    let pending = (try? await store.nonTerminalRequests()) ?? []
    let live = await transport.liveTasks()
    // Capture pre-existing unclosed activities before registering the Reconcile action.
    let openActions = await log.openActionsAtLaunch()
    let action = log.begin(
      "Reconcile", origin: .system,
      "\(pending.count) non-terminal request\(pending.count == 1 ? "" : "s") · \(live.count) live task\(live.count == 1 ? "" : "s") · \(openActions.count) open log action\(openActions.count == 1 ? "" : "s")"
    )
    var counts = (kept: 0, began: 0, reparsed: 0, handled: 0, interrupted: 0, grace: 0)
    var graced: [RequestSnapshot] = []
    // Track actions already finalized by service hooks to prevent redundant terminal logging.
    var closedByService: Set<ActionID> = []

    // Evaluate each non-terminal request against live transport tasks and filesystem artifacts.
    for snap in pending {
      let req = "req \(Format.short(snap.id)) (\(snap.state.rawValue), attempt \(snap.attempt))"
      if snap.state == .preparing {
        log.step(action, "\(req): interrupted, preparation never finished")
        if let closed = await service.markInterrupted(snap.id, reason: "\(Self.closedReason) (preparation)") {
          closedByService.insert(closed)
        }
        counts.interrupted += 1
        continue
      }
      // Reconcile with active transport task corresponding to the current attempt.
      if let task = live.first(where: { $0.requestID == snap.id && $0.attempt == snap.attempt }) {
        let began = snap.state == .retryScheduled && task.countOfBytesSent > 0
        await service.refreshLiveTask(snap.id, attempt: snap.attempt, taskIdentifier: task.taskIdentifier, began: began)
        log.step(action, "\(req): \(began ? "began; now inFlight" : "kept"), task \(task.taskIdentifier)")
        if began { counts.began += 1 } else { counts.kept += 1 }
        continue
      }
      // Reprocess completed payload if completion marker was committed before application termination.
      if FileManager.default.fileExists(atPath: files.completeMarkerURL(snap.id, attempt: snap.attempt).path) {
        switch await service.reparse(snap.id, attempt: snap.attempt) {
        case .reparsed:
          log.step(action, "\(req): re-parsed, the response was saved")
          counts.reparsed += 1
        case .interrupted:
          log.step(action, "\(req): interrupted, the connection ended without a response")
          counts.interrupted += 1
        case .alreadyHandled:
          log.step(action, "\(req): already handled, nothing to re-parse")
          counts.handled += 1
        }
        continue
      }
      log.step(action, "\(req): no live task; waiting \(Format.seconds(grace)) for a late completion")
      graced.append(snap)
      counts.grace += 1
    }

    // Reconcile activity log entries orphaned by prior application termination, preserving actions associated with live requests.
    let stillLive = Dictionary(
      ((try? await store.nonTerminalRequests()) ?? []).compactMap { s in s.activityActionID.map { ($0, s.id) } },
      uniquingKeysWith: { a, _ in a })
    let parents = Dictionary(openActions.compactMap { e in e.parentID.map { (e.actionID, $0) } }, uniquingKeysWith: { a, _ in a })
    // Traverse parent relationships with cycle protection to resolve root activity IDs.
    func root(_ id: ActionID) -> ActionID {
      var current = id
      var hops = 0
      while let p = parents[current], hops < 64 {
        current = p
        hops += 1
      }
      return current
    }
    func depth(_ id: ActionID) -> Int {
      var d = 0
      var current = id
      while let p = parents[current], d < 64 {
        current = p
        d += 1
      }
      return d
    }
    let handedToService = Set(pending.compactMap(\.activityActionID))
    var closed = 0
    // Finalize leaf activities before parent nodes to preserve natural closure ordering.
    for entry in openActions.sorted(by: { depth($0.actionID) > depth($1.actionID) }) {
      let top = root(entry.actionID)
      if closedByService.contains(top) { continue }
      if let request = stillLive[top] {
        if entry.actionID == top { log.step(top, "following req \(Format.short(request)) after a relaunch") }
        continue
      }
      if handedToService.contains(top) { continue }
      log.result(entry.actionID, .interrupted, "\(Self.closedReason)")
      closed += 1
    }

    // Await grace period for candidate orphaned requests to allow in-flight transport delegate events to deliver.
    await withTaskGroup(of: Void.self) { group in
      for snap in graced {
        group.addTask {
          await sleeper(grace)
          // Atomically verify state within service serial lock before recording interruption.
          await service.markInterrupted(
            snap.id, reason: "\(Self.closedReason) (no live task after the \(Format.seconds(grace)) grace)",
            expected: (snap.state, snap.attempt))
        }
      }
    }

    log.result(
      action, .success,
      "in \(Format.seconds(ContinuousClock.now - started)) · kept \(counts.kept) · began \(counts.began) · re-parsed \(counts.reparsed) · already handled \(counts.handled) · interrupted \(counts.interrupted) · grace \(counts.grace) · log actions closed \(closed)"
    )
  }
}
