import Foundation
import OSLog

/// The activity log's only file writer and the stream's only consumer (D§4.13). It keeps an index
/// of actions, not their entries, and answers control messages in stream order.
actor ActivityLogStore {
  struct Limits: Sendable {
    /// Rotate when the file passes this size…
    var rotateAbove: Int
    /// …keeping the newest whole entries within this size, plus open actions' begins.
    var keepAfterRotation: Int
    /// Slows every write, for tests of control-message ordering.
    var writeDelay: Duration = .zero

    static let standard = Limits(rotateAbove: 4 * 1024 * 1024, keepAfterRotation: 2 * 1024 * 1024)
  }

  static let sparseEvery = 256

  private let fileURL: URL
  private let mirror: @Sendable (ActivityEntry, String, String) -> Void
  private let limits: Limits
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  private var handle: FileHandle?
  private var fileSize: UInt64 = 0
  private var lastSequence = 0
  private var records: [ActionID: ActionRecord] = [:]
  /// (sequence, offset) at least every 256 entries and at every gap in the sequence numbers;
  /// between two points, lines have consecutive sequence numbers.
  private var sparse: [(sequence: Int, offset: UInt64)] = []
  private var lastIndexedSequence: Int?
  private var openAtLaunch: Set<ActionID> = []
  private var subscribers: [AsyncStream<ActivityLogStatus>.Continuation] = []

  init(fileURL: URL, mirror: @escaping @Sendable (ActivityEntry, String, String) -> Void, limits: Limits) {
    self.fileURL = fileURL
    self.mirror = mirror
    self.limits = limits
  }

  func run(_ events: AsyncStream<ActivityLogEvent>) async {
    load()
    for await event in events {
      await handle(event)
    }
    try? handle?.close()
    for s in subscribers { s.finish() }
  }

  // MARK: Events

  private func handle(_ event: ActivityLogEvent) async {
    switch event {
    case .entry(let entry, let rendered):
      if limits.writeDelay > .zero { try? await Task.sleep(for: limits.writeDelay) }
      accept(entry, rendered)
    case .resultOfOpenChild(let name, let parent, let outcome, let timestamp, let rendered):
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
      c.resume()
    case .entriesTree(let id, let c):
      c.resume(returning: tree(id))
    case .entriesAfter(let sequence, let c):
      c.resume(returning: entries(after: sequence))
    case .openActionsAtLaunch(let c):
      c.resume(returning: openBegins(openAtLaunch.filter { records[$0]?.isOpen == true }))
    case .actionRecords(let c):
      c.resume(returning: Array(records.values))
    case .status(let c):
      c.resume(returning: currentStatus())
    case .clear(let id, let timestamp, let c):
      clear(id: id, timestamp: timestamp)
      c.resume()
    case .subscribe(let s):
      subscribers.append(s)
      s.yield(currentStatus())
    }
  }

  /// Fills in what the facade couldn't know, enforces pairing, writes, mirrors and publishes.
  private func accept(_ incoming: ActivityEntry, _ rendered: RenderedMessage) {
    var entry = incoming
    let record = records[entry.actionID]
    if entry.name.isEmpty, let record { entry.name = record.name }
    if entry.parentID == nil, let parent = record?.parentID { entry.parentID = parent }
    if entry.kind == .begin, entry.origin == nil, let parent = entry.parentID {
      entry.origin = records[parent]?.origin
    }

    if entry.kind == .result {
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

  private func write(_ entry: ActivityEntry, _ rendered: RenderedMessage) {
    guard var line = try? encoder.encode(entry) else { return }
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
    if fileSize > UInt64(limits.rotateAbove) { rotate() }
  }

  private func index(_ e: ActivityEntry, sequence: Int, offset: UInt64) {
    if lastIndexedSequence.map({ sequence != $0 + 1 }) ?? true || sequence % Self.sparseEvery == 1 {
      sparse.append((sequence, offset))
    }
    lastIndexedSequence = sequence

    if var r = records[e.actionID] {
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
      records[e.actionID] = ActionRecord(
        id: e.actionID, name: e.name, origin: e.origin, parentID: e.parentID, isOpen: e.kind != .result,
        outcome: e.outcome, relatedID: e.relatedID, firstSequence: sequence, firstOffset: offset,
        beginSequence: e.kind == .begin ? sequence : nil, resultSequence: e.kind == .result ? sequence : nil)
    }
  }

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

  private func load() {
    do {
      try Self.ensureFile(fileURL)
    } catch {
      Log.store.error("activity log: cannot create the file: \(error.localizedDescription, privacy: .public)")
    }
    let data = (try? Data(contentsOf: fileURL)) ?? Data()
    rebuild(from: Self.decodeLines(data, firstSequence: 1, sparse: []))
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
      if let entry = try? decoder.decode(ActivityEntry.self, from: raw) {
        lines.append(Line(sequence: sequence, offset: offset, entry: entry, raw: Data(raw)))
        sequence += 1
      }
      start = end < data.endIndex ? data.index(after: end) : end
    }
    return lines
  }

  /// Rebuilds the index and sparse table from the file's lines, keeping what the old index knew
  /// about actions whose begins are gone (their origin and related action).
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
    lastSequence = max(lastSequence, lines.last?.sequence ?? 0)
  }

  // MARK: Reading

  private func readFrom(_ offset: UInt64) -> Data {
    guard let h = try? FileHandle(forReadingFrom: fileURL) else { return Data() }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    return (try? h.readToEnd()) ?? Data()
  }

  /// The sparse point to start reading from for sequence `s`.
  private func point(atOrBefore s: Int) -> (sequence: Int, offset: UInt64)? {
    sparse.last { $0.sequence <= s } ?? sparse.first
  }

  private func entries(after sequence: Int) -> [(Int, ActivityEntry)] {
    guard let start = point(atOrBefore: sequence + 1) else { return [] }
    return Self.decodeLines(readFrom(start.offset), baseOffset: start.offset, firstSequence: start.sequence, sparse: sparse)
      .filter { $0.sequence > sequence }
      .map { ($0.sequence, $0.entry) }
  }

  private func tree(_ id: ActionID) -> [ActivityEntry] {
    guard let r = records[id] else { return [] }
    // Everything in the tree comes after the action's first entry still in the file.
    let lines = Self.decodeLines(readFrom(r.firstOffset), baseOffset: r.firstOffset, firstSequence: r.firstSequence, sparse: sparse)
    return ActivityLogQuery.tree(id, in: lines.map(\.entry)).entries
  }

  private func openBegins(_ ids: Set<ActionID>) -> [ActivityEntry] {
    let starts = ids.compactMap { records[$0]?.firstOffset }
    guard let first = starts.min() else { return [] }
    return Self.decodeLines(readFrom(first), baseOffset: first, firstSequence: 0, sparse: [])
      .map(\.entry)
      .filter { $0.kind == .begin && ids.contains($0.actionID) }
  }

  private func currentStatus() -> ActivityLogStatus {
    let all = Array(records.values)
    return ActivityLogStatus(
      lastSequence: lastSequence, lastActionID: ActivityLogQuery.lastAction(all), lastErrorID: ActivityLogQuery.lastError(all))
  }

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
  private func rotate() {
    let lines = Self.decodeLines((try? Data(contentsOf: fileURL)) ?? Data(), firstSequence: 1, sparse: sparse)
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
      guard let raw = try? encoder.encode(entry) else { continue }
      lastSequence += 1
      lines.append(Line(sequence: lastSequence, offset: UInt64(data.count), entry: entry, raw: raw))
      appended.append((entry, lastSequence))
      data.append(raw)
      data.append(UInt8(ascii: "\n"))
    }
    do {
      guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.protectionKey: FileStore.protection])
      else { throw CocoaError(.fileWriteUnknown) }
      try? handle?.close()
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
    for (entry, _) in appended { mirror(entry, entry.message, "") }
  }

  // MARK: Files

  /// Creates `Logs/` and the file if needed, with the protection class and backup exclusion.
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

  static func excludeFromBackup(_ url: URL) {
    var u = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)
  }
}
