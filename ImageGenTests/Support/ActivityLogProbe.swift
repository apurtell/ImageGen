import Foundation
import Synchronization
import Testing

@testable import ImageGen

/// Test fixture wrapping an `ActivityLog` instance bound to an isolated `TestFileRoot` directory,
/// capturing mirrored OSLog events and providing inspection helpers for persisted JSONL records.
final class ActivityLogProbe: Sendable {
  struct MirrorCall: Sendable {
    let entry: ActivityEntry
    let publicText: String
    let privateText: String
  }

  let root: TestFileRoot
  let fileURL: URL
  let log: ActivityLog
  private final class Recorder: Sendable {
    let calls = Mutex<[MirrorCall]>([])
  }

  private let recorder = Recorder()

  init(
    root: TestFileRoot = TestFileRoot(), sanitize: @escaping @Sendable (String) -> String = { $0 },
    clock: @escaping @Sendable () -> Date = { Date() }, limits: ActivityLogStore.Limits = .standard
  ) {
    self.root = root
    fileURL = root.url.appendingPathComponent("ImageGen/Logs/activity.jsonl")
    let recorder = self.recorder
    log = ActivityLog(
      fileURL: fileURL, sanitize: sanitize,
      mirror: { entry, publicText, privateText in
        recorder.calls.withLock { $0.append(MirrorCall(entry: entry, publicText: publicText, privateText: privateText)) }
      }, clock: clock, limits: limits)
  }

  deinit {
    // Extends the temporary root lifetime until store teardown completes to prevent directory recreation races.
    let log = self.log
    let root = self.root
    Task.detached {
      await log.close()
      withExtendedLifetime(root) {}
    }
  }

  /// Snapshot of captured log mirror invocations recorded up to the current moment.
  var mirrorCalls: [MirrorCall] { recorder.calls.withLock { $0 } }

  /// Formatted diagnostic strings representing mirrored entries in `[name actionID] public | private` format.
  var osLogStrings: [String] {
    mirrorCalls.map { "[\($0.entry.name) \($0.entry.actionID)] \($0.publicText) | \($0.privateText)" }
  }

  /// Flushes pending actor writes and reads raw lines directly from the log file.
  func lines() async -> [String] {
    await log.flush()
    let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  /// Flushes pending actor writes and returns decoded `ActivityEntry` records.
  func entries() async -> [ActivityEntry] {
    await lines().compactMap { try? JSONDecoder().decode(ActivityEntry.self, from: Data($0.utf8)) }
  }

  /// Resolves the subtree of entries associated with the most recent top-level action of the specified name.
  func action(named name: String) async -> [ActivityEntry] {
    let all = await entries()
    guard let id = all.last(where: { $0.kind == .begin && $0.name == name && $0.parentID == nil })?.actionID else {
      return []
    }
    return ActivityLogQuery.tree(id, in: all).entries
  }

  func records() async -> [ActionRecord] {
    await log.flush()
    return await log.actionRecords()
  }

  /// Asserts that every unique action identifier in the log contains exactly one begin event and one result event.
  func assertPaired(sourceLocation: SourceLocation = #_sourceLocation) async {
    var begins: [ActionID: Int] = [:]
    var results: [ActionID: Int] = [:]
    for e in await entries() {
      if e.kind == .begin { begins[e.actionID, default: 0] += 1 }
      if e.kind == .result { results[e.actionID, default: 0] += 1 }
    }
    for id in Set(begins.keys).union(results.keys) {
      #expect(begins[id] == 1 && results[id] == 1, "action \(id): \(begins[id] ?? 0) begin(s), \(results[id] ?? 0) result(s)", sourceLocation: sourceLocation)
    }
  }
}
