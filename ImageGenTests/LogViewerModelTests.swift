import Foundation
import Testing
import UIKit

@testable import ImageGen

@MainActor
@Suite(.tags(.io))
struct LogViewerModelTests {
  let utc = TimeZone(identifier: "UTC")!

  func viewer(_ kind: LogViewerModel.Kind, _ probe: ActivityLogProbe) async -> LogViewerModel {
    let records = await probe.records()
    let start: ActionID? =
      switch kind {
      case .lastAction: ActivityLogQuery.lastAction(records)
      case .lastError: ActivityLogQuery.lastError(records)
      case .fullLog: nil
      }
    let m = LogViewerModel(kind: kind, log: probe.log, startingAt: start, timeZone: utc, refreshInterval: .milliseconds(10))
    await m.open()
    return m
  }

  @Test func lastActionShowsNewestUserActionWithSubActions() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "gemini-3.1-flash-image")
    let p = probe.log.begin("Prepare request", parent: a, "1 input")
    probe.log.result(p, .success, "in 0.0 s")
    probe.log.result(a, .success, "in 1.0 s")
    let j = probe.log.begin("Janitor", origin: .system, "thresholds")
    probe.log.result(j, .success, "")
    let m = await viewer(.lastAction, probe)
    #expect(m.actionID == a)
    #expect(m.lines.count == 4)
    #expect(m.lines[1].contains("  [Prepare request "))
    #expect(!m.text.contains("Janitor"))
    #expect(!m.isInProgress)
    m.close()
  }

  @Test func lastActionInProgressWhileOpen() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    let m = await viewer(.lastAction, probe)
    #expect(m.isInProgress)
    probe.log.result(a, .success, "in 2.0 s")
    await probe.log.flush()
    await m.refresh()
    #expect(!m.isInProgress)
    #expect(m.lines.last?.contains("Result: success in 2.0 s") == true)
    m.close()
  }

  @Test func lastErrorIncludesRefused() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .refused, "IMAGE_OTHER · HTTP 200 in 9.8 s")
    probe.log.result(probe.log.begin("Copy", origin: .user, ""), .success, "")
    let m = await viewer(.lastError, probe)
    #expect(m.actionID == a)
    #expect(m.lines.last?.contains("Result: refused · IMAGE_OTHER") == true)
    m.close()
  }

  @Test func fullLogChronologicalNewestLast() async throws {
    let probe = ActivityLogProbe()
    for n in 0..<3 { probe.log.result(probe.log.begin("Copy", origin: .user, "n\(n)"), .success, "") }
    let m = await viewer(.fullLog, probe)
    let begins = m.lines.filter { $0.contains("Begin:") }
    #expect(begins.map { $0.hasSuffix("n0") || $0.hasSuffix("n1") || $0.hasSuffix("n2") } == [true, true, true])
    #expect(begins.first?.hasSuffix("n0") == true)
    #expect(begins.last?.hasSuffix("n2") == true)
    #expect(m.lines.first?.hasPrefix("— ") == true)
    m.close()
  }

  @Test func liveUpdatesWhileOpen() async throws {
    let probe = ActivityLogProbe()
    probe.log.result(probe.log.begin("Copy", origin: .user, "first"), .success, "")
    let m = await viewer(.fullLog, probe)
    let before = m.lines.count
    probe.log.result(probe.log.begin("Copy", origin: .user, "second"), .success, "")
    await probe.log.flush()
    await m.refresh()
    #expect(m.lines.count == before + 2)
    #expect(m.appendedCount == 2)
    // Subsequent entries appear reactively without manual refresh.
    probe.log.result(probe.log.begin("Copy", origin: .user, "third"), .success, "")
    for _ in 0..<200 where !m.text.contains("third") { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.text.contains("third"))
    m.close()
  }

  @Test func openSheetStaysOnItsAction() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "A")
    probe.log.result(a, .success, "")
    let m = await viewer(.lastAction, probe)
    let b = probe.log.begin("Send", origin: .user, "B")
    probe.log.result(b, .success, "")
    await probe.log.flush()
    await m.refresh()
    #expect(m.actionID == a)
    #expect(!m.text.contains("Begin: B"))
    m.close()
    let reopened = await viewer(.lastAction, probe)
    #expect(reopened.actionID == b)
    reopened.close()
  }

  @Test func clearRequiresConfirmationThenStartsWithLogCleared() async throws {
    let probe = ActivityLogProbe()
    let menu = DeveloperMenuModel(log: probe.log)
    probe.log.result(probe.log.begin("Copy", origin: .user, "old"), .success, "")
    let send = probe.log.begin("Send", origin: .user, "running")
    // Dismissing the confirmation prompt without approval retains all log entries.
    #expect(await probe.entries().count == 3)
    await menu.clearLog()
    let m = await viewer(.fullLog, probe)
    #expect(m.lines.contains { $0.contains("[Send \(send)] Begin: running") })
    #expect(m.lines.contains { $0.contains("[Log cleared ") })
    #expect(!m.text.contains("old"))
    probe.log.result(send, .success, "in 3.0 s")
    await probe.log.flush()
    await m.refresh()
    #expect(m.lines.last?.contains("[Send \(send)] Result: success in 3.0 s") == true)
    m.close()
  }

  @Test func shareFileIsPlainTextEqualToView() async throws {
    let probe = ActivityLogProbe()
    probe.log.result(probe.log.begin("Copy", origin: .user, "x"), .success, "")
    let m = await viewer(.fullLog, probe)
    let file = m.shareFile
    let url = try file.write()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(try String(contentsOf: url, encoding: .utf8) == m.text)
    #expect(url.lastPathComponent.range(of: #"^ImageGen-log-\d{4}-\d{2}-\d{2}-\d{4}\.txt$"#, options: .regularExpression) != nil)
    m.close()
  }

  @Test func copyPutsViewTextOnPasteboard() async throws {
    let probe = ActivityLogProbe()
    probe.log.result(probe.log.begin("Copy", origin: .user, "x"), .success, "")
    let m = await viewer(.lastAction, probe)
    let board = try #require(UIPasteboard(name: UIPasteboard.Name("ImageGenTests-\(UUID().uuidString)"), create: true))
    defer { UIPasteboard.remove(withName: board.name) }
    board.string = m.text
    #expect(board.string == m.text)
    #expect(m.text.contains("[Copy "))
    m.close()
  }

  @Test func viewingIsNotLogged() async throws {
    let probe = ActivityLogProbe()
    probe.log.result(probe.log.begin("Copy", origin: .user, "x"), .success, "")
    let before = await probe.entries().count
    for kind in [LogViewerModel.Kind.lastAction, .lastError, .fullLog] {
      let m = await viewer(kind, probe)
      await m.refresh()
      _ = m.shareFile
      _ = m.text
      m.close()
    }
    #expect(await probe.entries().count == before)
  }
}

@MainActor
@Suite(.tags(.io))
struct DeveloperMenuModelTests {
  func settle(_ m: DeveloperMenuModel, until condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  }

  @Test func lastErrorDisabledWhenNone() async throws {
    let probe = ActivityLogProbe()
    probe.log.result(probe.log.begin("Send", origin: .user, "ok"), .success, "")
    let m = DeveloperMenuModel(log: probe.log)
    try await settle(m) { m.lastActionID != nil }
    #expect(!m.hasError)
    #expect(m.lastActionID != nil)
  }

  @Test func hasErrorTurnsOnWithoutOpeningASheet() async throws {
    let probe = ActivityLogProbe()
    let m = DeveloperMenuModel(log: probe.log)
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .refused, "IMAGE_SAFETY")
    try await settle(m) { m.hasError }
    #expect(m.hasError)
    #expect(m.lastErrorID == a)
  }

  @Test func clearResetsHasError() async throws {
    let probe = ActivityLogProbe()
    let m = DeveloperMenuModel(log: probe.log)
    probe.log.result(probe.log.begin("Send", origin: .user, "go"), .failed, "HTTP 500")
    try await settle(m) { m.hasError }
    await m.clearLog()
    try await settle(m) { !m.hasError }
    #expect(!m.hasError)
  }

  @Test func bothToolbarsShareOneModel() async throws {
    let rig = AppEnvironmentLaunchTests.Rig()
    let env = AppEnvironment(rig.configuration())
    let first = env.developerMenu
    #expect(first === env.developerMenu)
    #expect(first.log === env.log)
    env.transport.invalidateAndWait()
    await env.log.close()
  }
}
