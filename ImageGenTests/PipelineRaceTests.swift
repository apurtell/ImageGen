import Foundation
import Testing

@testable import ImageGen

/// Validates asynchronous edge case interleavings across concurrent pipeline operations,
/// including duplicate completion handling, cancellation races, and foreground retry re-creation.
@Suite(.tags(.integration))
struct PipelineRaceTests {
  typealias H = GenerationHarness

  /// Sets up an in-flight send left uncompleted across process restarts to simulate crash recovery.
  func relaunchedInFlight() async throws -> (h2: H, id: UUID, conv: UUID, send: ActionID) {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let send = try #require(try await h.snapshot(id).activityActionID)
    _ = await h.probe.lines()
    h.service.stop()
    return (try H(scripted: true, reuse: h), id, conv, send)
  }

  /// Waits until the Send action and every Late completion have their results.
  func settled(_ h: H, _ send: ActionID) async throws {
    try await h.until {
      let entries = await h.probe.entries()
      let lates = entries.filter { $0.name == "Late completion" && $0.kind == .begin }.map(\.actionID)
      return entries.contains { $0.actionID == send && $0.kind == .result }
        && lates.allSatisfy { late in entries.contains { $0.actionID == late && $0.kind == .result } }
    }
  }

  @Test func relaunchCompletionAndReparseSaveTheReplyOnce() async throws {
    let (h2, id, conv, send) = try await relaunchedInFlight()
    // Simulates concurrent response handling where transport completion and reconciler re-parsing execute simultaneously.
    h2.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    await h2.service.reparse(id, attempt: 1)
    #expect(try await h2.wait(id).state == .succeeded)
    try await settled(h2, send)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await h2.s.store.imageCount(conv: conv) == 1)
    let parses = ActivityLogQuery.tree(send, in: await h2.probe.entries()).entries.filter { $0.name == "Parse" && $0.kind == .begin }
    #expect(parses.count == 1)
    await h2.probe.assertPaired()
  }

  @Test func reparseAfterTheCompletionReportsAlreadyHandled() async throws {
    let (h2, id, conv, send) = try await relaunchedInFlight()
    // Transport completion finishes request processing prior to reconciler invocation.
    h2.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    #expect(try await h2.wait(id).state == .succeeded)
    try await settled(h2, send)
    #expect(await h2.service.reparse(id, attempt: 1) == .alreadyHandled)
    #expect(try await h2.s.store.imageCount(conv: conv) == 1)
    let parses = ActivityLogQuery.tree(send, in: await h2.probe.entries()).entries.filter { $0.name == "Parse" && $0.kind == .begin }
    #expect(parses.count == 1)
  }

  @Test func reparseSkipsAnAttemptThatMovedOn() async throws {
    let (h2, id, _, _) = try await relaunchedInFlight()
    try await h2.s.store.updateRequest(id) { p in
      p.attempt = 2
      p.state = .retryScheduled
    }
    // The reconciler targets an earlier attempt while a subsequent retry attempt is already active.
    #expect(await h2.service.reparse(id, attempt: 1) == .alreadyHandled)
    let snap = try await h2.snapshot(id)
    #expect(snap.state == .retryScheduled)
    #expect(snap.attempt == 2)
  }

  @Test func interruptionRacingACompletionKeepsTheLogHonest() async throws {
    let h = try H(scripted: true)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let send = try #require(try await h.snapshot(id).activityActionID)
    h.scripted!.complete(id, attempt: 1, status: 200, body: try FixtureLoader.data("Responses/resp_text_image.json"))
    await h.service.markInterrupted(id, reason: "the app was closed before this finished")
    _ = try await h.wait(id, for: [.succeeded, .interrupted])
    try await settled(h, send)
    try await Task.sleep(for: .milliseconds(300))
    let final = try await h.snapshot(id)
    let entries = await h.probe.entries()
    let late = entries.contains { $0.name == "Late completion" && $0.kind == .begin }
    let result = try #require(entries.last { $0.actionID == send && $0.kind == .result })
    // Verifies consistent outcome logging: completion wins as success or yields a late completion action, avoiding conflicting interruption logs.
    if final.state == .succeeded && !late { #expect(result.outcome == .success) }
    #expect(final.state == .succeeded || final.state == .interrupted)
    #expect(try await h.s.store.imageCount(conv: conv) <= 1)
  }

  @Test func stopDuringTheCivicRebuildIsHonoured() async throws {
    let h = try H(scripted: true)
    let gate = ManualSleeper()
    h.civicGate.withLock { $0 = { await gate.sleep(.zero) } }
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, status: 400, body: try FixtureLoader.data("Errors/err_400_civic.json"))
    try await h.until { gate.waitingCount == 1 }
    // Dispatches cancellation while request payload reconstruction is in progress prior to task instantiation.
    await h.service.cancel(requestID: id)
    gate.advance()
    #expect(try await h.wait(id).state == .cancelled)
    #expect(h.scripted!.jobs.value.count == 1)
    #expect(await h.probe.action(named: "Send").last?.outcome == .cancelled)
    await h.probe.assertPaired()
  }

  @Test func deletingTheChatDuringTheCivicRebuildPostsNothing() async throws {
    let h = try H(scripted: true, active: false)
    let gate = ManualSleeper()
    h.civicGate.withLock { $0 = { await gate.sleep(.zero) } }
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    let send = try #require(try await h.snapshot(id).activityActionID)
    h.scripted!.complete(id, attempt: 1, status: 400, body: try FixtureLoader.data("Errors/err_400_civic.json"))
    try await h.until { gate.waitingCount == 1 }
    _ = try await h.s.store.deleteConversation(conv)
    gate.advance()
    try await settled(h, send)
    #expect(h.notifications.value.isEmpty)
    let result = try #require(await h.probe.entries().last { $0.actionID == send && $0.kind == .result })
    #expect(result.outcome == .cancelled)
    #expect(result.message == "the request was deleted")
    #expect(h.scripted!.jobs.value.count == 1)
  }

  @Test func overlappingReactivationsReplaceTheRetryOnce() async throws {
    let h = try H(scripted: true, active: false)
    let conv = try await h.s.store.createConversation()
    let id = try await h.service.send(h.draft(conv, "x"))
    try await h.wait(id, for: [.inFlight])
    h.scripted!.complete(id, attempt: 1, status: 503, body: try FixtureLoader.data("Errors/err_503.json"))
    #expect(try await h.wait(id, for: [.retryScheduled]).nextAttemptCreatedInBackground)
    #expect(h.scripted!.jobs.value.count == 2)
    // Simulates rapid foreground reactivation cycles (e.g. system alert or Control Center toggles).
    h.activity.setActive(true)
    async let a: Void = h.service.appBecameActive()
    async let b: Void = h.service.appBecameActive()
    _ = await (a, b)
    #expect(h.scripted!.jobs.value.count == 3)
    let snap = try await h.snapshot(id)
    #expect(!snap.nextAttemptCreatedInBackground)
    #expect(Set(h.scripted!.jobs.value.map(\.attempt)).count == 3)
  }
}
