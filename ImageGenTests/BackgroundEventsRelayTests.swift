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
    // Send begin + result, Background events begin + result: all written before the handler ran.
    #expect(linesAtHandler == 4)
  }

  @Test func unknownIdentifierIsIgnored() async {
    let probe = ActivityLogProbe()
    let relay = BackgroundEventsRelay(log: probe.log)
    await relay.callAndClear(identifier: "nothing", completionsHandled: 0)
    #expect(await probe.entries().isEmpty)
  }
}
