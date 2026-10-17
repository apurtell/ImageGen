import Foundation
import Testing

@testable import ImageGen

@MainActor
@Suite(.tags(.io))
struct BackgroundEventsRelayTests {
  @Test func backgroundEventsActionLogged() async throws {
    let probe = ActivityLogProbe()
    let relay = BackgroundEventsRelay(log: probe.log)
    var called = false
    relay.store(identifier: "com.andrewpurtell.imagegen.generation") { called = true }
    #expect(relay.hasPending)
    await relay.callAndClear(identifier: "com.andrewpurtell.imagegen.generation", completionsHandled: 2)
    #expect(called)
    #expect(!relay.hasPending)
    let tree = await probe.action(named: "Background events")
    #expect(tree.first?.origin == .system)
    #expect(tree.first?.message == "session com.andrewpurtell.imagegen.generation")
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message.contains("2 completions handled") == true)
    await probe.assertPaired()
  }

  @Test func flushesBeforeCompletionHandler() async throws {
    let probe = ActivityLogProbe(limits: ActivityLogStore.Limits(rotateAbove: 1 << 30, keepAfterRotation: 1 << 29, writeDelay: .milliseconds(40)))
    let relay = BackgroundEventsRelay(log: probe.log)
    let send = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(send, .success, "in 1.0 s")
    var linesAtHandler = -1
    let url = probe.fileURL
    relay.store(identifier: "bg") {
      linesAtHandler = RecordingBackgroundTaskProvider.lineCount(url)
    }
    await relay.callAndClear(identifier: "bg", completionsHandled: 1)
    // Confirms that all pending log events flush to disk prior to system completion callback invocation.
    #expect(linesAtHandler == 4)
  }

  @Test func eventsFinishedBeforeHandlerStillCallIt() async throws {
    let probe = ActivityLogProbe()
    let relay = BackgroundEventsRelay(log: probe.log)
    await relay.callAndClear(identifier: "bg", completionsHandled: 3)
    var called = false
    relay.store(identifier: "bg") { called = true }
    for _ in 0..<200 where !called { try await Task.sleep(for: .milliseconds(10)) }
    #expect(called)
    #expect(!relay.hasPending)
    let tree = await probe.action(named: "Background events")
    #expect(tree.last?.outcome == .success)
    #expect(tree.last?.message.contains("3 completions handled before the system handler (events finished before the handler arrived)") == true)
    await probe.assertPaired()
  }

  @Test func staleEarlyFinishDoesNotEndALaterWake() async throws {
    let probe = ActivityLogProbe()
    var clock = ContinuousClock.now
    let relay = BackgroundEventsRelay(log: probe.log, now: { clock })
    // Simulates queued events dispatched on app launch without subsequent background completion callbacks.
    await relay.callAndClear(identifier: "bg", completionsHandled: 1)
    clock += .seconds(60)
    // Simulates a subsequent background wake occurring within the same process lifecycle.
    var called = false
    relay.store(identifier: "bg") { called = true }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!called)
    #expect(relay.hasPending)
    // Handler triggers once the new cycle's completions have resolved.
    await relay.callAndClear(identifier: "bg", completionsHandled: 2)
    #expect(called)
    #expect(await probe.action(named: "Background events").last?.message.contains("2 completions handled") == true)
  }

  @Test func unknownIdentifierIsIgnored() async {
    let probe = ActivityLogProbe()
    let relay = BackgroundEventsRelay(log: probe.log)
    await relay.callAndClear(identifier: "nothing", completionsHandled: 0)
    #expect(await probe.entries().isEmpty)
  }
}
