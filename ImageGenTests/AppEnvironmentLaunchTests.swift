import Foundation
import Testing
import UIKit

@testable import ImageGen

@MainActor
@Suite(.serialized, .tags(.integration))
struct AppEnvironmentLaunchTests {
  final class Rig {
    let root = TestFileRoot()
    let suite = "ImageGenTests.\(UUID().uuidString)"
    let sleeper = ManualSleeper()
    var useManualGrace = false

    func configuration(reset: Bool = false) -> AppEnvironment.Configuration {
      let sleeper = self.sleeper
      let manual = useManualGrace
      var c = AppEnvironment.Configuration(
        root: root.url.appendingPathComponent("ImageGen"), cachesRoot: root.url.appendingPathComponent("Caches"),
        transportConfiguration: MockURLProtocol.configuration(), sessionDescription: "ephemeral session",
        makeKeyStore: { InMemoryKeyStore(key: "k", registry: $0) }, defaults: UserDefaults(suiteName: suite)!,
        defaultsSuite: suite)
      c.inMemoryStore = true
      c.resetBeforeLaunch = reset
      c.makeBackgroundTasks = { RecordingBackgroundTaskProvider(log: $0) }
      c.deliverNotification = { _ in }
      c.connectivity = FakeConnectivityMonitor()
      c.reconcilerSleeper = { d in if manual { await sleeper.sleep(d) } }
      return c
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
  }

  func entries(_ env: AppEnvironment) async -> [ActivityEntry] {
    await env.log.flush()
    let text = (try? String(contentsOf: env.log.fileURL, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(ActivityEntry.self, from: Data($0.utf8)) }
  }

  @Test func reconcilerRunsWithoutFirstFrame() async throws {
    let rig = Rig()
    let env = AppEnvironment(rig.configuration())
    env.didFinishLaunching(applicationState: .background)
    await env.waitForReconciler()
    let all = await entries(env)
    #expect(all.contains { $0.name == "Reconcile" && $0.kind == .result })
    #expect(env.janitorTask == nil)
    env.transport.invalidateAndWait()
    await env.log.close()
  }

  @Test func janitorWaitsForReconciler() async throws {
    let rig = Rig()
    rig.useManualGrace = true
    let env = AppEnvironment(rig.configuration())
    // A request left in flight with no task, so the Reconciler waits out the grace period.
    let conv = try await env.store.createConversation()
    let record = try await env.store.createSend(
      SendRecordInput(
        conversationID: conv, promptText: "x", attachments: [],
        selection: Selection(imageIDs: [], reason: .noImage, clearPin: false), settings: InMemoryStore.settings,
        activityActionID: ActionID(raw: "0000")))
    try await env.store.updateRequest(record.requestID) { p in
      p.state = .inFlight
      p.attempt = 1
    }
    env.firstFrameAppeared()
    env.didFinishLaunching(applicationState: .active)
    for _ in 0..<500 where rig.sleeper.waitingCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(rig.sleeper.waitingCount == 1)
    #expect(env.janitorTask == nil)
    rig.sleeper.advance()
    await env.waitForReconciler()
    let janitor = try #require(env.janitorTask)
    _ = await janitor.value
    let all = await entries(env)
    let reconcileEnd = try #require(all.firstIndex { $0.name == "Reconcile" && $0.kind == .result })
    let janitorBegin = try #require(all.firstIndex { $0.name == "Janitor" && $0.kind == .begin })
    #expect(reconcileEnd < janitorBegin)
    env.transport.invalidateAndWait()
    await env.log.close()
  }

  @Test func launchActionIsFirstAndPaired() async throws {
    let rig = Rig()
    let env = AppEnvironment(rig.configuration())
    env.didFinishLaunching(applicationState: .background)
    await env.waitForReconciler()
    let all = await entries(env)
    let first = try #require(all.first)
    #expect(first.name == "Launch")
    #expect(first.kind == .begin)
    #expect(first.origin == .system)
    #expect(first.message.hasPrefix("ImageGen "))
    #expect(first.message.contains(" · iOS \(UIDevice.current.systemVersion) · mock mode off"))
    let launch = all.filter { $0.actionID == first.actionID }
    #expect(launch.map(\.kind) == [.begin, .step, .result])
    #expect(launch[1].message == "application state background")
    #expect(launch[2].message.contains("Reconciler started"))
    #expect(launch[2].outcome == .success)
    env.transport.invalidateAndWait()
    await env.log.close()
  }

  @Test func resetDeletesLogBeforeLaunchBegin() async throws {
    let rig = Rig()
    // An earlier run's log, including an open Launch.
    let earlier = ActivityLogProbe(root: rig.root)
    earlier.log.begin("Launch", origin: .system, "earlier run")
    earlier.log.result(earlier.log.begin("Copy", origin: .user, "x"), .success, "")
    _ = await earlier.lines()
    await earlier.log.close()
    try Data("x".utf8).write(to: rig.root.file("ImageGen/Images/old.png"))

    let env = AppEnvironment(rig.configuration(reset: true))
    env.didFinishLaunching(applicationState: .active)
    await env.waitForReconciler()
    let all = await entries(env)
    #expect(all.first?.name == "Launch")
    #expect(all.first?.message.contains("earlier run") == false)
    #expect(!all.contains { $0.name == "Log cleared" })
    #expect(!all.contains { $0.message == "earlier run" })
    #expect(all.filter { $0.name == "Launch" && $0.kind == .result }.count == 1)
    #expect(!FileManager.default.fileExists(atPath: rig.root.url.appendingPathComponent("ImageGen/Images/old.png").path))
    env.transport.invalidateAndWait()
    await env.log.close()
  }
}
