import Foundation
import Synchronization
import Testing

@testable import ImageGen

/// An `ActivityLog` on a `TestFileRoot` file with a recording OSLog sink (plan §2.2). Every query
/// awaits `flush()` first. Pass `root:` to open a second instance on the same file.
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
    // Keep the root until the store has finished, so it can't recreate Logs/ after the root is removed.
    let log = self.log
    let root = self.root
    Task.detached {
      await log.close()
      withExtendedLifetime(root) {}
    }
  }

  /// The mirror calls so far (await `flush()` first for completeness).
  var mirrorCalls: [MirrorCall] { recorder.calls.withLock { $0 } }

  /// What the OSLog mirror was given, as `public | private`.
  var osLogStrings: [String] {
    mirrorCalls.map { "[\($0.entry.name) \($0.entry.actionID)] \($0.publicText) | \($0.privateText)" }
  }

  /// The raw file lines.
  func lines() async -> [String] {
    await log.flush()
    let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  /// Every entry in the file, decoded.
  func entries() async -> [ActivityEntry] {
    await lines().compactMap { try? JSONDecoder().decode(ActivityEntry.self, from: Data($0.utf8)) }
  }

  /// The tree of the newest top-level action with that name.
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

  /// Every action in the file has exactly one begin and exactly one result.
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
