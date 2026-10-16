import Foundation

/// Runs once per process start, right after the transport session exists (D§4.7): matches
/// non-terminal requests with live tasks, re-parses saved responses, marks orphans interrupted
/// after a grace period, and closes the activity-log actions an earlier process left open.
struct Reconciler: Sendable {
  let store: DataStore
  let transport: any GenerationTransport
  let service: GenerationService
  let files: FileStore
  let log: ActivityLog
  var grace: Duration = .seconds(5)
  var sleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

  static let closedReason = "the app was closed before this finished"

  func run() async {
    let started = ContinuousClock.now
    let pending = (try? await store.nonTerminalRequests()) ?? []
    let live = await transport.liveTasks()
    let openActions = await log.openActionsAtLaunch()
    let action = log.begin(
      "Reconcile", origin: .system,
      "\(pending.count) non-terminal request\(pending.count == 1 ? "" : "s") · \(live.count) live task\(live.count == 1 ? "" : "s") · \(openActions.count) open log action\(openActions.count == 1 ? "" : "s")"
    )
    var counts = (kept: 0, began: 0, reparsed: 0, interrupted: 0, grace: 0)
    var graced: [RequestSnapshot] = []
    var closedByService: Set<ActionID> = []

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
      if let task = live.first(where: { $0.requestID == snap.id && $0.attempt == snap.attempt }) {
        let began = snap.state == .retryScheduled && task.countOfBytesSent > 0
        await service.refreshLiveTask(snap.id, taskIdentifier: task.taskIdentifier, began: began)
        log.step(action, "\(req): \(began ? "began; now inFlight" : "kept"), task \(task.taskIdentifier)")
        if began { counts.began += 1 } else { counts.kept += 1 }
        continue
      }
      if FileManager.default.fileExists(atPath: files.completeMarkerURL(snap.id, attempt: snap.attempt).path) {
        log.step(action, "\(req): re-parse, the response was saved")
        await service.reparse(snap.id)
        counts.reparsed += 1
        continue
      }
      log.step(action, "\(req): no live task; waiting \(Format.seconds(grace)) for a late completion")
      graced.append(snap)
      counts.grace += 1
    }

    // Close the actions an earlier process left open, except those following a live request.
    let stillLive = Dictionary(
      ((try? await store.nonTerminalRequests()) ?? []).compactMap { s in s.activityActionID.map { ($0, s.id) } },
      uniquingKeysWith: { a, _ in a })
    let parents = Dictionary(openActions.compactMap { e in e.parentID.map { (e.actionID, $0) } }, uniquingKeysWith: { a, _ in a })
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
    var closed = 0
    for entry in openActions.sorted(by: { depth($0.actionID) > depth($1.actionID) }) {
      let top = root(entry.actionID)
      if closedByService.contains(top) { continue }
      if let request = stillLive[top] {
        if entry.actionID == top { log.step(top, "following req \(Format.short(request)) after a relaunch") }
        continue
      }
      log.result(entry.actionID, .interrupted, "\(Self.closedReason)")
      closed += 1
    }

    // Grace: anything still waiting with no completion is interrupted.
    await withTaskGroup(of: Void.self) { group in
      for snap in graced {
        group.addTask {
          await sleeper(grace)
          guard let now = try? await store.requestSnapshot(snap.id), now.state == snap.state, now.attempt == snap.attempt
          else { return }
          await service.markInterrupted(snap.id, reason: "\(Self.closedReason) (no live task after the \(Format.seconds(grace)) grace)")
        }
      }
    }

    log.result(
      action, .success,
      "in \(Format.seconds(ContinuousClock.now - started)) · kept \(counts.kept) · began \(counts.began) · re-parsed \(counts.reparsed) · interrupted \(counts.interrupted) · grace \(counts.grace) · log actions closed \(closed)"
    )
  }
}
