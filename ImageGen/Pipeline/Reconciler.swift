import Foundation

/// Runs once per process start, right after the transport session exists (D§4.7): matches
/// non-terminal requests with live tasks, re-parses saved responses, marks orphans interrupted
/// after a grace period, and closes the activity-log actions an earlier process left open.
///
/// Place in the design: `AppEnvironment.didFinishLaunching` runs it in a detached task at utility
/// priority, even on a background relaunch that never draws a frame. The Janitor waits for it. It
/// reads the store, the live tasks and the log, and it changes requests only through the
/// `GenerationService` hooks (`markInterrupted`, `refreshLiveTask`, `reparse`).
///
/// Concurrency model: a `Sendable` struct with no state of its own, so nothing here needs a lock.
/// The transport's events run at the same time, so a completion can change a request after this
/// pass listed it. That is why it passes the state and attempt it saw, and each hook checks them
/// again inside the request's turn (see the primer, *Snapshot, then check again*).
struct Reconciler: Sendable {
  let store: DataStore
  let transport: any GenerationTransport
  let service: GenerationService
  let files: FileStore
  let log: ActivityLog
  /// How long to wait for a late completion before a request with no live task is interrupted.
  var grace: Duration = .seconds(5)
  /// Waits for the grace period; tests inject an instant one. `Task.sleep` throws only when its
  /// task is cancelled, and then the wait is over anyway, so `try?` is harmless.
  var sleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

  static let closedReason = "the app was closed before this finished"

  func run() async {
    let started = ContinuousClock.now
    let pending = (try? await store.nonTerminalRequests()) ?? []
    let live = await transport.liveTasks()
    // Read before the Reconcile action begins, so this list never contains the Reconcile action.
    let openActions = await log.openActionsAtLaunch()
    let action = log.begin(
      "Reconcile", origin: .system,
      "\(pending.count) non-terminal request\(pending.count == 1 ? "" : "s") · \(live.count) live task\(live.count == 1 ? "" : "s") · \(openActions.count) open log action\(openActions.count == 1 ? "" : "s")"
    )
    // A tuple with named fields, for the summary.
    var counts = (kept: 0, began: 0, reparsed: 0, handled: 0, interrupted: 0, grace: 0)
    var graced: [RequestSnapshot] = []
    // Actions that `markInterrupted` already closed; the log pass below must not close them again.
    var closedByService: Set<ActionID> = []

    // One decision for each request, in order (D§4.7 step 2). Each `await` waits for that request's
    // turn in the service.
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
      // A live task for the same attempt: keep it. Bytes sent means that a delayed task began while
      // the app was gone.
      if let task = live.first(where: { $0.requestID == snap.id && $0.attempt == snap.attempt }) {
        let began = snap.state == .retryScheduled && task.countOfBytesSent > 0
        await service.refreshLiveTask(snap.id, attempt: snap.attempt, taskIdentifier: task.taskIdentifier, began: began)
        log.step(action, "\(req): \(began ? "began; now inFlight" : "kept"), task \(task.taskIdentifier)")
        if began { counts.began += 1 } else { counts.kept += 1 }
        continue
      }
      // No task, but the response is complete on disk (the process died before or during the parse).
      if FileManager.default.fileExists(atPath: files.completeMarkerURL(snap.id, attempt: snap.attempt).path) {
        // The step is written after the service's answer, so it says what really happened. The
        // transport's completion may have ended the request since this pass listed it.
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

    // Close the actions an earlier process left open, except those following a live request.
    // The store is read again, because the decisions above ended some requests. Each open action
    // is traced to its root (the request action); the root decides for the whole tree.
    let stillLive = Dictionary(
      ((try? await store.nonTerminalRequests()) ?? []).compactMap { s in s.activityActionID.map { ($0, s.id) } },
      uniquingKeysWith: { a, _ in a })
    let parents = Dictionary(openActions.compactMap { e in e.parentID.map { (e.actionID, $0) } }, uniquingKeysWith: { a, _ in a })
    // Nested functions. The 64-hop limit stops a loop if a damaged log has a cycle of parents.
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
    // Deepest first: a child gets its own Result before its parent's Result would close it as
    // "parent finished first".
    for entry in openActions.sorted(by: { depth($0.actionID) > depth($1.actionID) }) {
      let top = root(entry.actionID)
      if closedByService.contains(top) { continue }
      if let request = stillLive[top] {
        if entry.actionID == top { log.step(top, "following req \(Format.short(request)) after a relaunch") }
        continue
      }
      // An action that follows a request this pass handed to the service (re-parsed, or finished by a
      // completion meanwhile) got its Result from the service, not from here.
      if handedToService.contains(top) { continue }
      log.result(entry.actionID, .interrupted, "\(Self.closedReason)")
      closed += 1
    }

    // Grace: anything still waiting with no completion is interrupted.
    // A task group runs one child task for each request, all at the same time, and waits for all
    // of them before `run` continues (structured tasks; see the primer, *Tasks and cancellation*).
    await withTaskGroup(of: Void.self) { group in
      for snap in graced {
        group.addTask {
          await sleeper(grace)
          // Only if nothing happened to it meanwhile; the service checks this in the request's turn,
          // so a completion being handled right now wins.
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
