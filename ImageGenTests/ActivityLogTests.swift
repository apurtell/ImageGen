import Foundation
import Synchronization
import Testing

@testable import ImageGen

@Suite(.tags(.io))
struct ActivityLogTests {
  /// Strictly increasing timestamps 1/512 s apart (exact in binary, distinct at millisecond precision),
  /// so file timestamps reveal the order calls took the facade's lock.
  final class TickClock: Sendable {
    private let ticks = Mutex(0)
    func next() -> Date {
      let n = ticks.withLock { t in
        t += 1
        return t
      }
      return Date(timeIntervalSince1970: 1_800_000_000 + Double(n) / 512)
    }
  }

  static let lighthouse = "a lighthouse at dusk"

  // MARK: Ordering

  @Test func orderPreservedUnderConcurrency() async throws {
    let clock = TickClock()
    let probe = ActivityLogProbe(clock: { clock.next() })
    let log = probe.log
    await withTaskGroup(of: Void.self) { group in
      for task in 0..<8 {
        if task % 2 == 0 {
          group.addTask { @MainActor in
            let id = log.begin("Task \(task)", origin: .system, "t\(task) #0")
            for n in 1..<249 { log.step(id, "t\(task) #\(n)") }
            log.result(id, .success, "t\(task) #249")
          }
        } else {
          group.addTask {
            let id = log.begin("Task \(task)", origin: .system, "t\(task) #0")
            for n in 1..<249 { log.step(id, "t\(task) #\(n)") }
            log.result(id, .success, "t\(task) #249")
          }
        }
      }
    }
    let entries = await probe.entries()
    #expect(entries.count == 2000)
    // File order is lock order: the clock is read under the lock, so timestamps strictly increase.
    for (a, b) in zip(entries, entries.dropFirst()) {
      #expect(a.timestamp < b.timestamp)
    }
    for task in 0..<8 {
      let mine = entries.filter { $0.message.hasPrefix("t\(task) #") }
      #expect(mine.map(\.message) == (0..<250).map { "t\(task) #\($0)" })
    }
    await probe.assertPaired()
  }

  @Test func controlMessagesOrderedAfterEarlierEntries() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let a = log.begin("Send", origin: .user, "go")
    for n in 0..<999 { log.step(a, "step \(n)") }
    let all = await log.entries(after: 0)
    #expect(all.count == 1000)
    #expect(all.map(\.0) == Array(1...1000))

    for n in 0..<100 { log.step(a, "late \(n)") }
    await log.clear()
    let lines = await probe.entries()
    #expect(!lines.contains { $0.message.hasPrefix("late ") })
    #expect(lines.map(\.name) == ["Send", "Log cleared", "Log cleared"])

    // flush() waits for a slowed-down store.
    let slow = ActivityLogProbe(limits: ActivityLogStore.Limits(rotateAbove: 1 << 30, keepAfterRotation: 1 << 29, writeDelay: .milliseconds(2)))
    let s = slow.log.begin("Slow", origin: .user, "")
    for n in 0..<49 { slow.log.step(s, "n \(n)") }
    await slow.log.flush()
    let raw = try String(contentsOf: slow.fileURL, encoding: .utf8)
    #expect(raw.split(separator: "\n").count == 50)
  }

  // MARK: Pairing

  @Test func exactlyOneBeginAndResult() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Save to Photos", origin: .user, "img 7f3a")
    probe.log.result(a, .success, "in 0.2 s · saved")
    probe.log.result(a, .failed, "second")
    let entries = await probe.entries()
    #expect(entries.filter { $0.kind == .result }.count == 1)
    #expect(entries.last?.outcome == .success)
    #expect(probe.mirrorCalls.filter { $0.entry.kind == .result }.count == 1)
    await probe.assertPaired()
  }

  @Test func parentResultClosesOpenChildrenAsInterrupted() async throws {
    let probe = ActivityLogProbe()
    let p = probe.log.begin("Send", origin: .user, "go")
    let c = probe.log.begin("Attempt 1", parent: p, "POST")
    let g = probe.log.begin("Parse", parent: c, "HTTP 200")
    probe.log.result(p, .failed, "in 1.0 s · bug")
    let entries = await probe.entries()
    #expect(entries.map(\.kind) == [.begin, .begin, .begin, .result, .result, .result])
    #expect(entries[3].actionID == g)
    #expect(entries[4].actionID == c)
    #expect(entries[3].outcome == .interrupted)
    #expect(entries[4].message == "parent finished first")
    #expect(entries[5].actionID == p)
    #expect(entries[1].origin == .user)
    let mirrored = probe.mirrorCalls.filter { $0.entry.outcome == .interrupted }
    #expect(mirrored.map(\.entry.name) == ["Parse", "Attempt 1"])
    await probe.assertPaired()
  }

  // MARK: Last Action

  @Test func lastActionIsNewestUserTopLevelWithSubActions() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let a = log.begin("Send", origin: .user, "first")
    let a1 = log.begin("Attempt 1", parent: a, "POST")
    log.result(a1, .success, "in 1.0 s")
    log.result(a, .success, "in 1.1 s")
    let b = log.begin("Regenerate", origin: .user, "second")
    let b1 = log.begin("Attempt 1", parent: b, "POST")
    log.result(b1, .success, "in 1.0 s")
    log.result(b, .success, "in 1.2 s")
    let records = await probe.records()
    #expect(ActivityLogQuery.lastAction(records) == b)
    let tree = await log.entries(tree: b)
    #expect(Set(tree.map(\.actionID)) == [b, b1])
    #expect(tree.count == 4)
    #expect((await log.status()).lastActionID == b)
  }

  @Test func lastActionInProgressMarked() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.step(a, "upload task 17 resumed")
    let view = ActivityLogQuery.tree(a, in: await probe.entries())
    #expect(view.isInProgress)
    #expect(!view.hasRotatedOutStart)
    probe.log.result(a, .success, "in 2.0 s")
    #expect(!ActivityLogQuery.tree(a, in: await probe.entries()).isInProgress)
  }

  @Test func lastActionSkipsNewerSystemActions() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .success, "")
    let j = probe.log.begin("Janitor", origin: .system, "thresholds")
    probe.log.result(j, .success, "")
    let late = probe.log.beginLateCompletion(of: a, "req 3f9c")
    probe.log.result(late, .success, "")
    #expect(ActivityLogQuery.lastAction(await probe.records()) == a)
  }

  @Test func lastActionFallsBackToSystemWhenNoUserAction() async throws {
    let probe = ActivityLogProbe()
    let l = probe.log.begin("Launch", origin: .system, "1.0 (1)")
    probe.log.result(l, .success, "")
    let j = probe.log.begin("Janitor", origin: .system, "thresholds")
    #expect(ActivityLogQuery.lastAction(await probe.records()) == j)
    #expect(ActivityLogQuery.lastAction([]) == nil)
  }

  @Test func lastActionShowsItsLateCompletion() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let a = log.begin("Send", origin: .user, "go")
    log.result(a, .interrupted, "the app was closed before this finished")
    let other = log.begin("Copy", origin: .user, "prompt")
    log.result(other, .success, "")
    let late = log.beginLateCompletion(of: a, "req 3f9c · original \(a)")
    let parse = log.begin("Parse", parent: late, "HTTP 200")
    log.result(parse, .success, "")
    log.result(late, .success, "in 30.0 s")

    let tree = await log.entries(tree: a)
    #expect(tree.map(\.actionID) == [a, a, late, parse, parse, late])
    let view = ActivityLogQuery.tree(a, in: await probe.entries())
    #expect(view.lateCompletionIDs == [late, parse])
    #expect(!view.isInProgress)
    let text = ActivityLogFormatter.lines(view, timeZone: TimeZone(identifier: "UTC")!)
    #expect(text.contains { $0.hasSuffix("(completed later)") })
  }

  // MARK: Last Error

  @Test func lastErrorIncludesRefused() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .refused, "IMAGE_OTHER · HTTP 200 in 9.8 s")
    let b = probe.log.begin("Copy", origin: .user, "")
    probe.log.result(b, .success, "")
    #expect(ActivityLogQuery.lastError(await probe.records()) == a)
    #expect((await probe.log.status()).lastErrorID == a)
  }

  @Test func lastErrorIncludesFailedAndInterrupted() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .failed, "HTTP 400")
    #expect(ActivityLogQuery.lastError(await probe.records()) == a)
    let b = probe.log.begin("Save to Photos", origin: .user, "img")
    probe.log.result(b, .interrupted, "the app was closed before this finished")
    #expect(ActivityLogQuery.lastError(await probe.records()) == b)
  }

  @Test func lastErrorIncludesEmptyReplyAsFailed() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .failed, "empty reply · finish MAX_TOKENS · HTTP 200 in 6.3 s")
    #expect(ActivityLogQuery.lastError(await probe.records()) == a)
  }

  @Test func lastErrorIgnoresCancelled() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .failed, "HTTP 500")
    let b = probe.log.begin("Save to Files", origin: .user, "img")
    probe.log.result(b, .cancelled, "")
    #expect(ActivityLogQuery.lastError(await probe.records()) == a)
  }

  @Test func lastErrorIncludesSubActions() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    let c = probe.log.begin("Attempt 1", parent: a, "POST")
    probe.log.result(c, .failed, "HTTP 503")
    probe.log.result(a, .failed, "HTTP 503")
    let id = try #require(ActivityLogQuery.lastError(await probe.records()))
    #expect(id == a)
    #expect(Set(await probe.log.entries(tree: id).map(\.actionID)) == [a, c])
  }

  @Test func lastErrorSkipsInterruptedResolvedBySuccessfulLateCompletion() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let older = log.begin("Send", origin: .user, "older")
    log.result(older, .failed, "HTTP 400")
    let a = log.begin("Send", origin: .user, "go")
    log.result(a, .interrupted, "closed")
    #expect(ActivityLogQuery.lastError(await probe.records()) == a)
    let late = log.beginLateCompletion(of: a, "req")
    log.result(late, .success, "in 3.0 s")
    #expect(ActivityLogQuery.lastError(await probe.records()) == older)

    // A late completion that fails keeps the original in Last Error.
    let b = log.begin("Send", origin: .user, "b")
    log.result(b, .interrupted, "closed")
    let lateB = log.beginLateCompletion(of: b, "req")
    log.result(lateB, .failed, "HTTP 500")
    #expect(ActivityLogQuery.lastError(await probe.records()) == b)
  }

  @Test func lastErrorNilWhenNone() async throws {
    let probe = ActivityLogProbe()
    let a = probe.log.begin("Send", origin: .user, "go")
    probe.log.result(a, .success, "")
    #expect(ActivityLogQuery.lastError(await probe.records()) == nil)
    #expect((await probe.log.status()).lastErrorID == nil)
  }

  @Test func partialFailureEndsFailed() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let attach = log.begin("Attach", origin: .user, "Photos · 3 items · tray 0 · max long edge 2048")
    let children = (0..<3).map { log.begin("Prepare attachment", parent: attach, "item \($0)") }
    log.result(children[0], .success, "")
    log.result(children[1], .failed, "unsupported type public.svg-image")
    log.result(children[2], .success, "")
    log.result(attach, .failed, "in 1.9 s · 2 of 3 imported and prepared · 1 failed: unsupported type public.svg-image")
    #expect(ActivityLogQuery.lastError(await probe.records()) == attach)
    await probe.assertPaired()
  }

  // MARK: Rotation

  @Test func rotationKeepsWholeEntries() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let filler = String(repeating: "x", count: 1000)
    log.result(log.begin("Settings change", origin: .user, "first"), .success, "")
    // Write in batches until the file shrinks: that's the rotation past 4 MB.
    var previous = 0
    var n = 0
    rotating: while n < 10_000 {
      for _ in 0..<50 {
        log.result(log.begin("Settings change", origin: .user, "n \(n) \(filler)"), .success, "")
        n += 1
      }
      await log.flush()
      let size = try FileManager.default.attributesOfItem(atPath: probe.fileURL.path)[.size] as? Int ?? 0
      if size < previous { break rotating }
      previous = size
    }
    #expect(previous > 4 * 1024 * 1024 - 100_000)
    log.result(log.begin("Settings change", origin: .user, "newest"), .success, "")

    let lines = await probe.lines()
    let size = try FileManager.default.attributesOfItem(atPath: probe.fileURL.path)[.size] as? Int ?? 0
    // At most 2 MB, plus whatever the batch wrote after the rotation.
    #expect(size <= 2 * 1024 * 1024 + 100_000)
    #expect(size > 1024 * 1024)
    let entries = lines.compactMap { try? JSONDecoder().decode(ActivityEntry.self, from: Data($0.utf8)) }
    #expect(entries.count == lines.count)
    #expect(entries.suffix(2).map(\.message) == ["newest", ""])
    #expect(!entries.contains { $0.message == "first" })
    #expect(!entries.contains { $0.message.hasPrefix("n 0 ") })
    // The store's own reads agree after rotation, with increasing sequence numbers.
    let after = await log.entries(after: 0)
    #expect(after.map(\.1) == entries)
    #expect(after.map(\.0) == after.map(\.0).sorted())
    #expect(Set(after.map(\.0)).count == after.count)
    await probe.assertPaired()

    // A closed action whose begin rotated out is flagged.
    let small = ActivityLogProbe(limits: ActivityLogStore.Limits(rotateAbove: 100_000, keepAfterRotation: 50_000))
    let x = small.log.begin("Copy", origin: .user, "x begins")
    for i in 0..<100 { small.log.result(small.log.begin("Copy", origin: .user, "a\(i) \(filler)"), .success, "") }
    small.log.result(x, .success, "x ends")
    for i in 0..<30 { small.log.result(small.log.begin("Copy", origin: .user, "b\(i) \(filler)"), .success, "") }
    let smallEntries = await small.entries()
    #expect(!smallEntries.contains { $0.actionID == x && $0.kind == .begin })
    let view = ActivityLogQuery.tree(x, in: smallEntries)
    #expect(view.hasRotatedOutStart)
    #expect(view.entries.map(\.kind) == [.result])
    let text = ActivityLogFormatter.lines(view, timeZone: TimeZone(identifier: "UTC")!)
    #expect(text.first?.hasSuffix("(earlier entries rotated out)") == true)
    #expect(await small.log.entries(tree: x).map(\.message) == ["x ends"])
  }

  @Test func rotationKeepsOpenActionBegins() async throws {
    let probe = ActivityLogProbe(limits: ActivityLogStore.Limits(rotateAbove: 200_000, keepAfterRotation: 100_000))
    let log = probe.log
    let send = log.begin("Send", origin: .user, "kept open")
    let filler = String(repeating: "y", count: 500)
    for n in 0..<600 { log.result(log.begin("Copy", origin: .user, "\(n) \(filler)"), .success, "") }
    let lines = await probe.entries()
    #expect(lines.first?.actionID == send)
    #expect(lines.first?.kind == .begin)
    #expect(!lines.contains { $0.message.hasPrefix("0 ") })

    let second = ActivityLogProbe(root: probe.root, limits: ActivityLogStore.Limits(rotateAbove: 200_000, keepAfterRotation: 100_000))
    #expect(await second.log.openActionsAtLaunch().map(\.actionID) == [send])
    second.log.result(send, .success, "in 30.0 s")
    let result = try #require(await second.entries().last)
    #expect(result.name == "Send")
    #expect(result.kind == .result)
    #expect(await second.records().first { $0.id == send }?.origin == .user)
  }

  // MARK: Clear

  @Test func clearDeletesFileAndStartsWithLogCleared() async throws {
    let probe = ActivityLogProbe()
    for n in 0..<10 { probe.log.result(probe.log.begin("Copy", origin: .user, "\(n)"), .success, "") }
    await probe.log.clear()
    let entries = await probe.entries()
    #expect(entries.map(\.name) == ["Log cleared", "Log cleared"])
    #expect(entries.map(\.kind) == [.begin, .result])
    #expect(entries[0].origin == .user)
    #expect(entries[0].message.contains("20 entries"))
    #expect(entries[0].message.contains("MB"))
    #expect(entries[1].outcome == .success)
    #expect(await probe.log.entries(after: 0).count == 2)
    await probe.assertPaired()
  }

  @Test func clearKeepsOpenActionBegins() async throws {
    let probe = ActivityLogProbe()
    let log = probe.log
    let done = log.begin("Copy", origin: .user, "done")
    log.result(done, .success, "")
    let send = log.begin("Send", origin: .user, "in flight")
    let attempt = log.begin("Attempt 1", parent: send, "POST")
    log.step(send, "before clear")
    await log.clear()
    #expect(await probe.entries().map(\.name) == ["Send", "Attempt 1", "Log cleared", "Log cleared"])

    // A reload still reports them open.
    let second = ActivityLogProbe(root: probe.root)
    #expect(Set(await second.log.openActionsAtLaunch().map(\.actionID)) == [send, attempt])

    second.log.step(send, "after clear")
    second.log.result(attempt, .success, "HTTP 200")
    second.log.result(send, .success, "in 14.2 s")
    let entries = await second.entries()
    #expect(entries.suffix(3).map(\.name) == ["Send", "Attempt 1", "Send"])
    #expect(entries.suffix(3).map(\.kind) == [.step, .result, .result])
    await second.assertPaired()
  }

  // MARK: Across instances

  @Test func persistsAcrossInstances() async throws {
    let first = ActivityLogProbe()
    var ids: [ActionID] = []
    for n in 0..<20 {
      let id = first.log.begin("Copy", origin: .user, "\(n)")
      first.log.result(id, .success, "")
      ids.append(id)
    }
    let before = await first.entries()
    let second = ActivityLogProbe(root: first.root)
    #expect(await second.log.entries(after: 0).map(\.1) == before)
    let next = second.log.begin("Copy", origin: .user, "new")
    #expect(!ids.contains(next))
  }

  @Test func idSeededFromFileNotDefaults() async throws {
    let empty = ActivityLogProbe()
    #expect(empty.log.begin("Copy", origin: .user, "") == ActivityLog.actionID(counter: 0))

    let first = ActivityLogProbe()
    var ids: [ActionID] = []
    for n in 0..<50 { ids.append(first.log.begin("Send", origin: .user, "\(n)")) }
    _ = await first.lines()
    #expect(Set(ids).count == 50)
    let newest = try #require(ActivityLog.counter(of: ids.last!))
    let second = ActivityLogProbe(root: first.root)
    let next = second.log.begin("Send", origin: .user, "next")
    #expect(!ids.contains(next))
    #expect(next == ActivityLog.actionID(counter: newest &+ 1))
    #expect(ActivityLog.counter(of: next) == newest &+ 1)
  }

  @Test func openActionsFromEarlierInstanceReportedAndClosable() async throws {
    let first = ActivityLogProbe()
    let a = first.log.begin("Save to Photos", origin: .user, "img")
    let b = first.log.begin("Send", origin: .user, "go")
    let b1 = first.log.begin("Attempt 2", parent: b, "POST")
    let closed = first.log.begin("Copy", origin: .user, "")
    first.log.result(closed, .success, "")
    _ = await first.lines()

    let second = ActivityLogProbe(root: first.root)
    let mine = second.log.begin("Launch", origin: .system, "1.0")
    let open = await second.log.openActionsAtLaunch()
    #expect(Set(open.map(\.actionID)) == [a, b, b1])
    #expect(!open.map(\.actionID).contains(mine))

    second.log.result(a, .interrupted, "the app was closed before this finished")
    second.log.result(ofOpenChild: "Attempt 2", of: b, .interrupted, "the app was closed")
    let entries = await second.entries()
    #expect(entries.contains { $0.actionID == a && $0.kind == .result && $0.name == "Save to Photos" })
    #expect(entries.contains { $0.actionID == b1 && $0.kind == .result && $0.outcome == .interrupted && $0.parentID == b })
    #expect(Set(await second.log.openActionsAtLaunch().map(\.actionID)) == [b])
  }

  @Test func adoptedEntriesGetNameAndOrigin() async throws {
    let first = ActivityLogProbe()
    let b = first.log.begin("Send", origin: .user, "go")
    _ = await first.lines()

    let second = ActivityLogProbe(root: first.root)
    second.log.step(b, "relaunched; continuing")
    let parse = second.log.begin("Parse", parent: b, "HTTP 200")
    let entries = await second.entries()
    let step = try #require(entries.first { $0.actionID == b && $0.kind == .step })
    #expect(step.name == "Send")
    let parseBegin = try #require(entries.first { $0.actionID == parse })
    #expect(parseBegin.origin == .user)
    #expect(parseBegin.parentID == b)

    let mirrored = try #require(second.mirrorCalls.first { $0.entry.actionID == b && $0.entry.kind == .step })
    #expect(mirrored.entry.name == "Send")
    #expect(ActivityLog.categoryName(for: mirrored.entry.name) == "pipeline")
    #expect(second.mirrorCalls.first { $0.entry.actionID == parse }?.entry.origin == .user)
  }

  @Test func truncatedLastLineRecovered() async throws {
    let first = ActivityLogProbe()
    first.log.result(first.log.begin("Copy", origin: .user, "one"), .success, "")
    _ = await first.lines()
    let handle = try FileHandle(forWritingTo: first.fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"timestamp":"2026-10-16T09:41:00.000Z","actionID":"ab"#.utf8))
    try handle.close()

    let second = ActivityLogProbe(root: first.root)
    let id = second.log.begin("Copy", origin: .user, "after the cut")
    second.log.result(id, .success, "")
    let lines = await second.lines()
    #expect(lines.count == 4)
    for line in lines {
      #expect((try? JSONDecoder().decode(ActivityEntry.self, from: Data(line.utf8))) != nil)
    }
    let third = ActivityLogProbe(root: first.root)
    #expect(await third.entries().contains { $0.message == "after the cut" })
  }

  @Test func fileProtectionAndBackupExclusion() async throws {
    let probe = ActivityLogProbe(limits: ActivityLogStore.Limits(rotateAbove: 20_000, keepAfterRotation: 10_000))
    func check(_ when: String) throws {
      for url in [probe.fileURL, probe.fileURL.deletingLastPathComponent()] {
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true, "\(when): \(url.lastPathComponent)")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
          // The simulator doesn't implement Data Protection, so the class reads back nil there;
          // it's checked on the device (M10).
          #expect(protection == nil || protection == .completeUntilFirstUserAuthentication, "\(when)")
        #else
          #expect(protection == .completeUntilFirstUserAuthentication, "\(when): \(url.lastPathComponent)")
        #endif
      }
    }
    probe.log.result(probe.log.begin("Copy", origin: .user, ""), .success, "")
    _ = await probe.lines()
    try check("after create")
    for n in 0..<200 { probe.log.result(probe.log.begin("Copy", origin: .user, "\(n) \(String(repeating: "z", count: 100))"), .success, "") }
    _ = await probe.lines()
    let size = try FileManager.default.attributesOfItem(atPath: probe.fileURL.path)[.size] as? Int ?? 0
    #expect(size <= 20_000)
    try check("after rotation")
    await probe.log.clear()
    try check("after clear")
  }

  @Test func osLogMirrorKeepsPrivateSegmentsPrivate() async throws {
    let probe = ActivityLogProbe()
    let title = "Lighthouse ideas"
    let id = probe.log.begin(
      "Send", origin: .user,
      "gemini-3.1-flash-image · 16:9 · chat \(private: title) · prompt \(private: "\"\(Self.lighthouse)\"")")
    probe.log.result(id, .success, "in 1.0 s")
    await probe.log.flush()
    let call = try #require(probe.mirrorCalls.first)
    #expect(call.publicText == "gemini-3.1-flash-image · 16:9 · chat <private> · prompt <private>")
    #expect(!call.publicText.contains(Self.lighthouse))
    #expect(call.privateText == "Lighthouse ideas · \"a lighthouse at dusk\"")
    let file = try #require(await probe.entries().first)
    #expect(file.message == "gemini-3.1-flash-image · 16:9 · chat Lighthouse ideas · prompt \"a lighthouse at dusk\"")
  }

  @Test func sanitizerAppliedBeforeWriting() async throws {
    let registry = SecretRegistry()
    registry.register("s3cret-value")
    let probe = ActivityLogProbe(sanitize: Redactor.forLog(secrets: { registry.all }))
    probe.log.result(
      probe.log.begin("Validate key", origin: .user, "key \(private: "s3cret-value") · GET models?key=abc"), .failed, "")
    let line = try #require(await probe.lines().first)
    #expect(!line.contains("s3cret-value"))
    #expect(!line.contains("key=abc"))
    #expect(!probe.osLogStrings.joined().contains("s3cret-value"))
  }

  // MARK: Formatter

  @Test func formatterLineFormat() {
    let utc = TimeZone(identifier: "UTC")!
    func at(_ s: String) -> Date { try! Date(s, strategy: ActivityEntry.timestampStyle) }
    let send = ActionID(raw: "a1b2")
    let prep = ActionID(raw: "3c5e")
    let entries = [
      ActivityEntry(timestamp: at("2026-10-15T23:59:59.900Z"), actionID: ActionID(raw: "0001"), name: "Janitor", kind: .result, outcome: .success, message: "in 0.1 s · staging 0"),
      ActivityEntry(timestamp: at("2026-10-16T14:02:11.384Z"), actionID: send, name: "Send", kind: .begin, origin: .user, message: "gemini-3.1-flash-image · 16:9"),
      ActivityEntry(timestamp: at("2026-10-16T14:02:11.390Z"), actionID: prep, parentID: send, name: "Prepare request", kind: .begin, message: "1 input"),
      ActivityEntry(timestamp: at("2026-10-16T14:02:11.396Z"), actionID: prep, parentID: send, name: "Prepare request", kind: .result, outcome: .success, message: "in 0.0 s · body.json 1.3 MB"),
      ActivityEntry(timestamp: at("2026-10-16T14:02:25.598Z"), actionID: send, name: "Send", kind: .step, message: "saved reply: 1 image"),
      ActivityEntry(timestamp: at("2026-10-16T14:05:12.007Z"), actionID: send, name: "Send", kind: .result, outcome: .refused, message: "IMAGE_OTHER · HTTP 200 in 9.8 s"),
    ]
    let lines = ActivityLogFormatter.lines(ActivityLogQuery.all(entries), timeZone: utc)
    #expect(lines == [
      "— 2026-10-15 —",
      "             (earlier entries rotated out)",
      "23:59:59.900 [Janitor 0001] Result: success in 0.1 s · staging 0",
      "— 2026-10-16 —",
      "14:02:11.384 [Send a1b2] Begin: gemini-3.1-flash-image · 16:9",
      "14:02:11.390   [Prepare request 3c5e] Begin: 1 input",
      "14:02:11.396   [Prepare request 3c5e] Result: success in 0.0 s · body.json 1.3 MB",
      "14:02:25.598 [Send a1b2] Step: saved reply: 1 image",
      "14:05:12.007 [Send a1b2] Result: refused · IMAGE_OTHER · HTTP 200 in 9.8 s",
    ])
    #expect(ActivityLogFormatter.lines(ActivityLogQuery.all([]), timeZone: utc) == ["No log entries"])
    #expect(ActivityLogFormatter.text(ActivityLogQuery.all(Array(entries.suffix(1))), timeZone: utc)
      == "— 2026-10-16 —\n             (earlier entries rotated out)\n14:05:12.007 [Send a1b2] Result: refused · IMAGE_OTHER · HTTP 200 in 9.8 s")
  }

  @Test func actionIDsRoundTrip() {
    for counter: UInt16 in [0, 1, 2, 999, 65535] {
      let id = ActivityLog.actionID(counter: counter)
      #expect(id.raw.count == 4)
      #expect(id.raw == id.raw.lowercased())
      #expect(ActivityLog.counter(of: id) == counter)
    }
    #expect(ActivityLog.actionID(counter: 1) != ActivityLog.actionID(counter: 2))
    #expect(ActivityLog.idMultiplier &* ActivityLog.idInverse == 1)
  }
}
