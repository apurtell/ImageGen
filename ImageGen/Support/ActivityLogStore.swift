import Foundation
import OSLog

/// The activity log's only file writer and the stream's only consumer (D§4.13). It keeps an index
/// of actions, not their entries, and answers control messages in stream order.
///
/// `ActivityLog` creates the store and runs `run` in a detached task; no other code calls it. It is an
/// `actor` (see the primer, *Actors*), but with one caller the stream, not the actor's queue, sets
/// the order. `run` handles each event to the end before it reads the next. The only `await` inside
/// `handle` is a test delay, and since `run` is the only caller, no other event can start during it.
/// So each event sees the effects of every event before it.
///
/// The file is JSON Lines: one entry per line, appended with one `write` and no fsync, so a written
/// entry survives a kill but not a power loss. The index (`records` and `sparse`) lets the store fill
/// in names and origins, enforce the Begin/Step/Result pairing rule and answer queries without
/// keeping entries in memory. Rotation and Clear rewrite the file through a temporary file and an
/// atomic rename, and never drop the begin of an open action.
actor ActivityLogStore {
  /// Size limits (D§4.13 Size cap). Tests pass small values.
  struct Limits: Sendable {
    /// Rotate when the file passes this size…
    var rotateAbove: Int
    /// …keeping the newest whole entries within this size, plus open actions' begins.
    var keepAfterRotation: Int
    /// Slows every write, for tests of control-message ordering.
    var writeDelay: Duration = .zero

    static let standard = Limits(rotateAbove: 4 * 1024 * 1024, keepAfterRotation: 2 * 1024 * 1024)
  }

  /// A sparse point at least every this many entries.
  static let sparseEvery = 256

  private let fileURL: URL
  /// The OSLog mirror (`ActivityLog.osLogMirror`, or a test's recorder).
  private let mirror: @Sendable (ActivityEntry, String, String) -> Void
  private let limits: Limits
  /// `.withoutEscapingSlashes` keeps paths such as `/v1beta/models` readable in the file.
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  /// nil after a failed open, or after a write failure that couldn't be repaired; `write` opens the
  /// file again before the next entry.
  private var handle: FileHandle?
  /// The offset where the next line goes: the file's length while `handle` is open.
  private var fileSize: UInt64 = 0
  /// The number of the newest line. Numbers start at 1 when the file loads, so they are valid only in
  /// this process. Rotation and Clear keep the numbers of the lines they keep.
  private var lastSequence = 0
  /// The action index: one record for each action with an entry in the file.
  private var records: [ActionID: ActionRecord] = [:]
  /// (sequence, offset) at least every 256 entries and at every gap in the sequence numbers;
  /// between two points, lines have consecutive sequence numbers.
  /// So a read can start at any point and still number its lines correctly.
  private var sparse: [(sequence: Int, offset: UInt64)] = []
  /// The number of the last line `index` saw, to find gaps.
  private var lastIndexedSequence: Int?
  /// The actions open when the file loaded, before this process's first entry.
  private var openAtLaunch: Set<ActionID> = []
  /// Status streams from `ActivityLog.changes()`. `publish` drops the ones whose reader went away.
  private var subscribers: [AsyncStream<ActivityLogStatus>.Continuation] = []

  init(fileURL: URL, mirror: @escaping @Sendable (ActivityEntry, String, String) -> Void, limits: Limits) {
    self.fileURL = fileURL
    self.mirror = mirror
    self.limits = limits
  }

  /// The store's whole life: load the file, handle each event in stream order, then close.
  /// `for await` waits for the next event without blocking a thread. The loop ends when the facade
  /// finishes the stream (`close()` or its `deinit`). The events already queued are still delivered
  /// first, so every queued entry is written and every queued control message is answered.
  func run(_ events: AsyncStream<ActivityLogEvent>) async {
    load()
    for await event in events {
      await handle(event)
    }
    try? handle?.close()  // Every line is already in the file; a close error loses nothing.
    for s in subscribers { s.finish() }
  }

  // MARK: Events

  /// Handles one event. Each control message's continuation is resumed here, exactly once.
  private func handle(_ event: ActivityLogEvent) async {
    switch event {
    case .entry(let entry, let rendered):
      if limits.writeDelay > .zero { try? await Task.sleep(for: limits.writeDelay) }  // Test only; never cancelled.
      accept(entry, rendered)
    case .resultOfOpenChild(let name, let parent, let outcome, let timestamp, let rendered):
      // The newest open sub-action with that name. With none, there is nothing to end: report it
      // instead of writing a result for an action that isn't open.
      guard let child = records.values.filter({ $0.parentID == parent && $0.name == name && $0.isOpen })
        .max(by: { $0.firstSequence < $1.firstSequence })
      else {
        Log.store.error("activity log: no open sub-action \(name, privacy: .public) of \(parent.raw, privacy: .public)")
        return
      }
      accept(
        ActivityEntry(timestamp: timestamp, actionID: child.id, name: "", kind: .result, outcome: outcome, message: rendered.fileText),
        rendered)
    case .flush(let c):
      // Every earlier entry is already written: events arrive in order and `accept` writes at once.
      c.resume()
    case .entriesTree(let id, let c):
      c.resume(returning: tree(id))
    case .entriesAfter(let sequence, let c):
      c.resume(returning: entries(after: sequence))
    case .openActionsAtLaunch(let c):
      // Some of them may have closed since the load; return only those still open.
      c.resume(returning: openBegins(openAtLaunch.filter { records[$0]?.isOpen == true }))
    case .actionRecords(let c):
      c.resume(returning: Array(records.values))
    case .status(let c):
      c.resume(returning: currentStatus())
    case .clear(let id, let timestamp, let c):
      clear(id: id, timestamp: timestamp)
      c.resume()
    case .subscribe(let s):
      // The current status first, so a new reader doesn't wait for the next write.
      subscribers.append(s)
      s.yield(currentStatus())
    }
  }

  /// Fills in what the facade couldn't know, enforces pairing, writes, mirrors and publishes.
  /// The facade sends steps and results with no name or parent, and sub-action begins with no
  /// origin. The index supplies them, also for an action adopted from an earlier process.
  private func accept(_ incoming: ActivityEntry, _ rendered: RenderedMessage) {
    var entry = incoming
    let record = records[entry.actionID]
    if entry.name.isEmpty, let record { entry.name = record.name }
    if entry.parentID == nil, let parent = record?.parentID { entry.parentID = parent }
    if entry.kind == .begin, entry.origin == nil, let parent = entry.parentID {
      entry.origin = records[parent]?.origin
    }

    if entry.kind == .result {
      // Pairing: exactly one Result for each action. A second one isn't written, so the mirror
      // doesn't see it either.
      if let record, !record.isOpen {
        Log.store.error(
          "activity log: dropped a second result for \(entry.name, privacy: .public) \(entry.actionID.raw, privacy: .public)")
        return
      }
      closeOpenChildren(of: entry.actionID, at: entry.timestamp)
    }
    write(entry, rendered)
    publish()
  }

  /// The backstop: open sub-actions of a finishing parent end interrupted, deepest first.
  /// Each gets `Result: interrupted · parent finished first`. It guards against a bug; it is not a
  /// mechanism. The plan's tests check that no normal path triggers it (D§4.13 Pairing). The
  /// recursion closes a child's own children before the child.
  private func closeOpenChildren(of parent: ActionID, at timestamp: Date) {
    let children = records.values.filter { $0.parentID == parent && $0.isOpen }.sorted { $0.firstSequence < $1.firstSequence }
    for child in children {
      closeOpenChildren(of: child.id, at: timestamp)
      let message = "parent finished first"
      write(
        ActivityEntry(
          timestamp: timestamp, actionID: child.id, parentID: parent, name: child.name, kind: .result,
          outcome: .interrupted, message: message),
        .plain(message))
    }
  }

  // MARK: Writing

  /// Appends one line, then indexes it, mirrors it and rotates when the file is too large. After a
  /// failed write none of that happens: the entry is in neither the index nor the mirror.
  private func write(_ entry: ActivityEntry, _ rendered: RenderedMessage) {
    guard var line = try? encoder.encode(entry) else { return }  // Strings only: encoding doesn't fail.
    line.append(UInt8(ascii: "\n"))
    if handle == nil { openForAppend() }
    guard let handle else { return }
    do {
      try handle.write(contentsOf: line)
    } catch {
      Log.store.error("activity log: write failed: \(error.localizedDescription, privacy: .public)")
      // Part of the line may be in the file (a full disk): cut it off, so the next entry starts on
      // a line of its own and the index's offsets still match the file.
      do {
        try handle.truncate(atOffset: fileSize)
        try handle.seek(toOffset: fileSize)
      } catch {
        // Can't repair it now: reopen before the next write, which finds the true end of the file.
        try? handle.close()  // The handle is discarded either way.
        self.handle = nil
      }
      return
    }
    let offset = fileSize
    fileSize += UInt64(line.count)
    lastSequence += 1
    index(entry, sequence: lastSequence, offset: offset)
    mirror(entry, rendered.publicText, rendered.privateText)
    // After the index update, so the rewrite keeps this entry and knows its action's state.
    if fileSize > UInt64(limits.rotateAbove) { rotate() }
  }

  /// Records one line in the sparse table and the action index. `write` and `rebuild` both use it,
  /// so an index built from the file matches one kept up to date entry by entry.
  private func index(_ e: ActivityEntry, sequence: Int, offset: UInt64) {
    // A point at the first line (nil), after a gap (lines kept by a rotation, or a number used by
    // a failed rewrite), and every `sparseEvery` lines.
    if lastIndexedSequence.map({ sequence != $0 + 1 }) ?? true || sequence % Self.sparseEvery == 1 {
      sparse.append((sequence, offset))
    }
    lastIndexedSequence = sequence

    if var r = records[e.actionID] {
      // A later entry of a known action. `isOpen` turns false at the Result and never turns back.
      if r.name.isEmpty { r.name = e.name }
      if e.kind == .begin {
        r.beginSequence = sequence
        r.origin = r.origin ?? e.origin
      }
      if e.kind == .result {
        r.isOpen = false
        r.outcome = e.outcome
        r.resultSequence = sequence
      }
      records[e.actionID] = r
    } else {
      // The action's first entry still in the file: its begin, unless the begin rotated out.
      records[e.actionID] = ActionRecord(
        id: e.actionID, name: e.name, origin: e.origin, parentID: e.parentID, isOpen: e.kind != .result,
        outcome: e.outcome, relatedID: e.relatedID, firstSequence: sequence, firstOffset: offset,
        beginSequence: e.kind == .begin ? sequence : nil, resultSequence: e.kind == .result ? sequence : nil)
    }
  }

  /// Opens the file for appending and takes `fileSize` from its true end. On failure `handle` stays
  /// nil, and the next `write` tries again.
  private func openForAppend() {
    do {
      try Self.ensureFile(fileURL)
      let h = try FileHandle(forWritingTo: fileURL)
      fileSize = try h.seekToEnd()
      handle = h
    } catch {
      Log.store.error("activity log: cannot open the file: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: Loading

  /// Builds the index from the whole file, once, at the start of `run`. `ActivityLog.prepareFile`
  /// has already cut off a partial last line.
  private func load() {
    do {
      try Self.ensureFile(fileURL)
    } catch {
      Log.store.error("activity log: cannot create the file: \(error.localizedDescription, privacy: .public)")
    }
    let data = (try? Data(contentsOf: fileURL)) ?? Data()  // Unreadable: start with an empty index.
    rebuild(from: Self.decodeLines(data, firstSequence: 1, sparse: []))
    // No entry of this process is in the file yet, so these were left open by an earlier process.
    openAtLaunch = Set(records.values.filter(\.isOpen).map(\.id))
    openForAppend()
  }

  /// A decoded line: its sequence number, byte offset, entry and raw bytes.
  struct Line {
    let sequence: Int
    let offset: UInt64
    let entry: ActivityEntry
    let raw: Data
  }

  /// Decodes lines from `data` (which starts at byte `baseOffset` of the file), numbering them from
  /// `firstSequence` and resetting the number at each sparse point.
  /// A line that doesn't decode gets no number, the same on every read, so the numbers match the
  /// index. A `static` function of an actor uses no actor state and needs no `await`.
  static func decodeLines(
    _ data: Data, baseOffset: UInt64 = 0, firstSequence: Int, sparse: [(sequence: Int, offset: UInt64)]
  ) -> [Line] {
    let decoder = JSONDecoder()
    var points = sparse.filter { $0.offset >= baseOffset }[...]
    var lines: [Line] = []
    var sequence = firstSequence
    var start = data.startIndex
    while start < data.endIndex {
      let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
      let offset = baseOffset + UInt64(start - data.startIndex)
      while let p = points.first, p.offset < offset { points = points.dropFirst() }
      if let p = points.first, p.offset == offset { sequence = p.sequence }
      let raw = data[start..<end]
      if let entry = try? decoder.decode(ActivityEntry.self, from: raw) {  // A bad line is skipped.
        lines.append(Line(sequence: sequence, offset: offset, entry: entry, raw: Data(raw)))
        sequence += 1
      }
      start = end < data.endIndex ? data.index(after: end) : end
    }
    return lines
  }

  /// Rebuilds the index and sparse table from the file's lines, keeping what the old index knew
  /// about actions whose begins are gone (their origin and related action).
  /// Used at load (with an empty old index) and after each rewrite.
  private func rebuild(from lines: [Line]) {
    let old = records
    records = [:]
    sparse = []
    lastIndexedSequence = nil
    for line in lines {
      index(line.entry, sequence: line.sequence, offset: line.offset)
    }
    for (id, var r) in records {
      if let o = old[id] {
        r.origin = r.origin ?? o.origin
        r.relatedID = r.relatedID ?? o.relatedID
        records[id] = r
      }
    }
    // At load this takes the file's last number. After a rewrite the appended lines have already
    // moved `lastSequence` on.
    lastSequence = max(lastSequence, lines.last?.sequence ?? 0)
  }

  // MARK: Reading

  /// Reads from `offset` to the end with its own read handle. The store is the only writer and
  /// handles one event at a time, so the file doesn't change during the read.
  private func readFrom(_ offset: UInt64) -> Data {
    guard let h = try? FileHandle(forReadingFrom: fileURL) else { return Data() }  // Unreadable: empty answer.
    defer { try? h.close() }  // Read only: a close error loses nothing.
    try? h.seek(toOffset: offset)  // A failed seek gives a short or empty read below.
    return (try? h.readToEnd()) ?? Data()  // Unreadable: empty answer.
  }

  /// The sparse point to start reading from for sequence `s`.
  /// The first point when `s` is older than everything in the file.
  private func point(atOrBefore s: Int) -> (sequence: Int, offset: UInt64)? {
    sparse.last { $0.sequence <= s } ?? sparse.first
  }

  /// Reads only from the sparse point before `sequence + 1`, then drops the older lines.
  private func entries(after sequence: Int) -> [(Int, ActivityEntry)] {
    guard let start = point(atOrBefore: sequence + 1) else { return [] }
    return Self.decodeLines(readFrom(start.offset), baseOffset: start.offset, firstSequence: start.sequence, sparse: sparse)
      .filter { $0.sequence > sequence }
      .map { ($0.sequence, $0.entry) }
  }

  private func tree(_ id: ActionID) -> [ActivityEntry] {
    guard let r = records[id] else { return [] }
    // Everything in the tree comes after the action's first entry still in the file.
    // That includes Late completions, which begin after the original action has ended.
    let lines = Self.decodeLines(readFrom(r.firstOffset), baseOffset: r.firstOffset, firstSequence: r.firstSequence, sparse: sparse)
    return ActivityLogQuery.tree(id, in: lines.map(\.entry)).entries
  }

  /// The begin entries of `ids`, read from the oldest one's offset. An open action's first entry is
  /// its begin, because rotation and Clear always keep it. The numbers aren't needed, so no sparse
  /// table is passed.
  private func openBegins(_ ids: Set<ActionID>) -> [ActivityEntry] {
    let starts = ids.compactMap { records[$0]?.firstOffset }
    guard let first = starts.min() else { return [] }
    return Self.decodeLines(readFrom(first), baseOffset: first, firstSequence: 0, sparse: [])
      .map(\.entry)
      .filter { $0.kind == .begin && ids.contains($0.actionID) }
  }

  /// From the index alone, without a file read.
  private func currentStatus() -> ActivityLogStatus {
    let all = Array(records.values)
    return ActivityLogStatus(
      lastSequence: lastSequence, lastActionID: ActivityLogQuery.lastAction(all), lastErrorID: ActivityLogQuery.lastError(all))
  }

  /// Sends the status to every subscriber, and removes the ones whose stream has ended.
  private func publish() {
    guard !subscribers.isEmpty else { return }
    let status = currentStatus()
    subscribers.removeAll { s in
      if case .terminated = s.yield(status) { return true }
      return false
    }
  }

  // MARK: Rotation and clear

  /// Rewrites the file to the newest whole entries within the limit, plus the begins of open
  /// actions ahead of them, through a temporary file and an atomic swap.
  /// Without those begins an open action would lose its name and origin, and if the process died,
  /// nothing would close it (D§4.13 Size cap). Called by `write` when the file passes `rotateAbove`.
  private func rotate() {
    let lines = Self.decodeLines((try? Data(contentsOf: fileURL)) ?? Data(), firstSequence: 1, sparse: sparse)
    // Walk back from the newest line while the window stays within `keepAfterRotation`.
    var kept = 0
    var windowStart = lines.count
    while windowStart > 0 {
      let size = lines[windowStart - 1].raw.count + 1
      if kept + size > limits.keepAfterRotation { break }
      kept += size
      windowStart -= 1
    }
    let openIDs = Set(records.values.filter(\.isOpen).map(\.id))
    let openBegins = lines[..<windowStart].filter { $0.entry.kind == .begin && openIDs.contains($0.entry.actionID) }
    replaceFile(with: Array(openBegins) + Array(lines[windowStart...]), appending: [])
  }

  /// Handles the Clear control message. The stream is ordered, so every entry sent before it is
  /// already written. Keeps the begins of open actions, then appends the Log cleared action's Begin
  /// and Result. The index keeps those actions open, so their later entries still pair, and
  /// `openActionsAtLaunch()` still finds them after a relaunch (D§4.13 Clear).
  private func clear(id: ActionID, timestamp: Date) {
    let lines = Self.decodeLines((try? Data(contentsOf: fileURL)) ?? Data(), firstSequence: 1, sparse: sparse)
    let openIDs = Set(records.values.filter(\.isOpen).map(\.id))
    let openBegins = lines.filter { $0.entry.kind == .begin && openIDs.contains($0.entry.actionID) }
    let removedBytes = max(0, Int(fileSize) - openBegins.reduce(0) { $0 + $1.raw.count + 1 })
    let removedCount = lines.count - openBegins.count
    let keptNames = openBegins.map { "\($0.entry.name) \($0.entry.actionID)" }
    let begin = "remove \(String(format: "%.1f", Double(removedBytes) / 1_048_576)) MB · \(removedCount) entries"
      + " · keep \(keptNames.count) open action\(keptNames.count == 1 ? "" : "s")"
      + (keptNames.isEmpty ? "" : " (\(keptNames.joined(separator: ", ")))")
    let added = [
      ActivityEntry(timestamp: timestamp, actionID: id, name: "Log cleared", kind: .begin, origin: .user, message: begin),
      ActivityEntry(timestamp: timestamp, actionID: id, name: "Log cleared", kind: .result, outcome: .success, message: "done"),
    ]
    replaceFile(with: openBegins, appending: added)
    publish()
  }

  /// Writes `kept` (keeping their sequence numbers) then `appending` (new sequence numbers) to a
  /// temporary file, swaps it in and rebuilds the index.
  ///
  /// The temporary file is complete before `rename`, which replaces the old file in one step, so a
  /// crash leaves the old file or the new one, never a mix. The temporary file gets the protection
  /// class when it is created. Backup exclusion is set again after the swap, because the flag doesn't
  /// survive a replace (D§4.13 Storage and writing). On failure the old file and index stay. The
  /// numbers taken for `appending` are then unused, and `index` records the gap at the next write.
  private func replaceFile(with kept: [Line], appending: [ActivityEntry]) {
    let temp = fileURL.deletingLastPathComponent().appendingPathComponent(".activity-\(UUID().uuidString).tmp")
    var data = Data()
    var lines: [Line] = []
    for line in kept {
      lines.append(Line(sequence: line.sequence, offset: UInt64(data.count), entry: line.entry, raw: line.raw))
      data.append(line.raw)
      data.append(UInt8(ascii: "\n"))
    }
    var appended: [(ActivityEntry, Int)] = []
    for entry in appending {
      guard let raw = try? encoder.encode(entry) else { continue }  // Strings only: encoding doesn't fail.
      lastSequence += 1
      lines.append(Line(sequence: lastSequence, offset: UInt64(data.count), entry: entry, raw: raw))
      appended.append((entry, lastSequence))
      data.append(raw)
      data.append(UInt8(ascii: "\n"))
    }
    do {
      guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.protectionKey: FileStore.protection])
      else { throw CocoaError(.fileWriteUnknown) }
      // Close the old file's handle before the swap; `openForAppend` opens the new file below.
      try? handle?.close()  // The handle is discarded either way.
      handle = nil
      guard rename(temp.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
      Self.excludeFromBackup(fileURL)
    } catch {
      // Cleanup of the temporary file after the failure that is already being handled.
      try? FileManager.default.removeItem(at: temp)
      Log.store.error("activity log: rewrite failed: \(error.localizedDescription, privacy: .public)")
      openForAppend()
      return
    }
    rebuild(from: lines)
    openForAppend()
    // Mirror the appended entries only once they are in the file, so the mirror matches the file.
    for (entry, _) in appended { mirror(entry, entry.message, "") }
  }

  // MARK: Files

  /// Creates `Logs/` and the file if needed, with the protection class and backup exclusion.
  /// The protection class lets a background relaunch write after the first unlock (see the primer,
  /// *Data protection*).
  static func ensureFile(_ url: URL) throws {
    let dir = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileStore.createDirectory(dir)
    }
    excludeFromBackup(dir)
    if !FileManager.default.fileExists(atPath: url.path) {
      guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileStore.protection])
      else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
    excludeFromBackup(url)
  }

  /// Keeps the log on this device. `setResourceValues` changes the `URL` value, so it needs a `var`
  /// copy.
  static func excludeFromBackup(_ url: URL) {
    var u = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)  // Best effort: a failure only lets the log into a backup.
  }
}
