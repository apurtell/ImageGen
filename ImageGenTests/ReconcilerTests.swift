import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.integration))
struct ReconcilerTests {
  typealias H = GenerationHarness

  /// A request left by an earlier process in `state` at attempt 1, with its Send (and Attempt 1) open.
  func leftOver(_ h: H, state: RequestState, attemptOpen: Bool = true) async throws -> (id: UUID, send: ActionID) {
    let conv = try await h.s.store.createConversation()
    let send = h.probe.log.begin("Send", origin: .user, "earlier process")
    if attemptOpen { h.probe.log.begin("Attempt 1", parent: send, "POST") }
    let record = try await h.s.send(conv, prompt: "x", action: send)
    try await h.s.store.updateRequest(record.requestID) { p in
      p.state = state
      p.attempt = state == .preparing ? 0 : 1
      p.taskIdentifier = .some(41)
    }
    _ = await h.probe.lines()
    return (record.requestID, send)
  }

  /// A new process on the same files: a new log, store actor, scripted transport and service.
  func relaunch(_ h: H, live: [LiveTask] = [], graceSleeper: ManualSleeper? = nil) throws -> (H, Reconciler) {
    h.service.stop()
    let h2 = try H(scripted: true, reuse: h)
    h2.scripted!.live.withLock { $0 = live }
    var r = Reconciler(store: h2.s.store, transport: h2.scripted!, service: h2.service, files: h2.s.files, log: h2.probe.log)
    if let graceSleeper { r.sleeper = { await graceSleeper.sleep($0) } } else { r.sleeper = { _ in } }
    return (h2, r)
  }

  @Test func liveTaskKept() async throws {
    let h = try H(scripted: true)
    let (id, send) = try await leftOver(h, state: .inFlight)
    let (h2, r) = try relaunch(h, live: [LiveTask(requestID: id, attempt: 1, taskIdentifier: 77, countOfBytesSent: 100)])
    await r.run()
    let snap = try await h2.snapshot(id)
    #expect(snap.state == .inFlight)
    #expect(snap.taskIdentifier == 77)
    // actionOfLiveRequestKeptOpen
    let open = await h2.probe.log.openActionsAtLaunch()
    #expect(Set(open.map(\.actionID)).contains(send))
    #expect(await h2.probe.entries().contains { $0.actionID == send && $0.kind == .step && $0.message.contains("following req") })
    #expect(!(await h2.probe.entries()).contains { $0.actionID == send && $0.kind == .result })
  }

  @Test func liveDelayedTaskThatBeganMovesToInFlight() async throws {
    let h = try H(scripted: true)
    let (id, _) = try await leftOver(h, state: .retryScheduled)
    let (h2, r) = try relaunch(h, live: [LiveTask(requestID: id, attempt: 1, taskIdentifier: 78, countOfBytesSent: 5000)])
    await r.run()
    #expect(try await h2.snapshot(id).state == .inFlight)
  }

  @Test func orphanInterruptedAfterGrace() async throws {
    let h = try H(scripted: true)
    let (id, _) = try await leftOver(h, state: .inFlight)
    let grace = ManualSleeper()
    let (h2, r) = try relaunch(h, graceSleeper: grace)
    let run = Task { await r.run() }
    try await h2.until { grace.waitingCount == 1 }
    #expect(try await h2.snapshot(id).state == .inFlight)
    #expect(grace.requested == [.seconds(5)])
    grace.advance()
    await run.value
    #expect(try await h2.snapshot(id).state == .interrupted)
  }

  @Test func lateCompletionOverridesInterrupted() async throws {
    let h = try H(scripted: true)
    let (id, _) = try await leftOver(h, state: .inFlight)
    let (h2, r) = try relaunch(h)
    await r.run()
    #expect(try await h2.snapshot(id).state == .interrupted)
    h2.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    #expect(try await h2.wait(id, for: [.succeeded]).state == .succeeded)
  }

  @Test func forceQuitCancelBecomesInterrupted() async throws {
    let h = try H(scripted: true)
    let (id, _) = try await leftOver(h, state: .inFlight)
    let grace = ManualSleeper()
    let (h2, r) = try relaunch(h, graceSleeper: grace)
    let run = Task { await r.run() }
    try await h2.until { grace.waitingCount == 1 }
    h2.scripted!.complete(id, attempt: 1, error: .cancelled, cancelReason: NSURLErrorCancelledReasonUserForceQuitApplication)
    let snap = try await h2.wait(id)
    #expect(snap.state == .interrupted)
    grace.advance()
    await run.value
    #expect(try await h2.snapshot(id).state == .interrupted)
  }

  @Test func completeMarkerReparsed() async throws {
    let h = try H(scripted: true)
    let (id, send) = try await leftOver(h, state: .inFlight)
    try FileStore.createDirectory(h.s.files.requestDir(id))
    let acc = ResponseAccumulator(files: h.s.files)
    acc.append(try FixtureLoader.data("Responses/resp_text_image.json"), requestID: id, attempt: 1, taskIdentifier: 9)
    _ = acc.complete(requestID: id, attempt: 1, taskIdentifier: 9, httpStatus: 200)
    let (h2, r) = try relaunch(h)
    await r.run()
    #expect(try await h2.snapshot(id).state == .succeeded)
    let tree = ActivityLogQuery.tree(send, in: await h2.probe.entries())
    #expect(tree.entries.last?.outcome == .success)
  }

  @Test func storedParsingStateReparsed() async throws {
    let h = try H(scripted: true)
    let (id, _) = try await leftOver(h, state: .parsing)
    try FileStore.createDirectory(h.s.files.requestDir(id))
    let acc = ResponseAccumulator(files: h.s.files)
    acc.append(try FixtureLoader.data("Responses/resp_image_safety.json"), requestID: id, attempt: 1, taskIdentifier: 9)
    _ = acc.complete(requestID: id, attempt: 1, taskIdentifier: 9, httpStatus: 200)
    let (h2, r) = try relaunch(h)
    await r.run()
    #expect(try await h2.snapshot(id).state == .refused)
  }

  @Test func preparingMarkedInterrupted() async throws {
    let h = try H(scripted: true)
    let (id, send) = try await leftOver(h, state: .preparing, attemptOpen: false)
    let (h2, r) = try relaunch(h)
    await r.run()
    #expect(try await h2.snapshot(id).state == .interrupted)
    let results = await h2.probe.entries().filter { $0.actionID == send && $0.kind == .result }
    #expect(results.count == 1)
    #expect(results.first?.outcome == .interrupted)
  }

  @Test func reconcileActionLogged() async throws {
    let h = try H(scripted: true)
    let (a, _) = try await leftOver(h, state: .preparing, attemptOpen: false)
    let (b, _) = try await leftOver(h, state: .inFlight)
    let (h2, r) = try relaunch(h, live: [LiveTask(requestID: b, attempt: 1, taskIdentifier: 5, countOfBytesSent: 1)])
    await r.run()
    let tree = await h2.probe.action(named: "Reconcile")
    let begin = try #require(tree.first)
    #expect(begin.origin == .system)
    #expect(begin.message.hasPrefix("2 non-terminal requests · 1 live task"))
    let steps = tree.filter { $0.kind == .step }
    #expect(steps.count == 2)
    #expect(steps.contains { $0.message.contains("req \(Format.short(a))") && $0.message.contains("interrupted") })
    #expect(steps.contains { $0.message.contains("req \(Format.short(b))") && $0.message.contains("kept") })
    #expect(tree.last?.outcome == .success)
  }

  @Test func orphanedLogActionsClosedAsInterrupted() async throws {
    let h = try H(scripted: true)
    let save = h.probe.log.begin("Save to Photos", origin: .user, "img 7f3a")
    _ = await h.probe.lines()
    let (h2, r) = try relaunch(h)
    await r.run()
    let result = try #require(await h2.probe.entries().last { $0.actionID == save })
    #expect(result.kind == .result)
    #expect(result.outcome == .interrupted)
    #expect(result.message == "the app was closed before this finished")
    #expect(result.name == "Save to Photos")
  }

  @Test func graceExpiryClosesActionInterrupted() async throws {
    let h = try H(scripted: true)
    let (_, send) = try await leftOver(h, state: .inFlight)
    let (h2, r) = try relaunch(h)
    await r.run()
    let entries = await h2.probe.entries()
    let result = try #require(entries.last { $0.actionID == send && $0.kind == .result })
    #expect(result.outcome == .interrupted)
    #expect(result.message.contains("grace"))
    #expect(entries.contains { $0.name == "Attempt 1" && $0.kind == .result && $0.outcome == .interrupted })
    await h2.probe.assertPaired()
  }
}
