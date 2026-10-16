import Foundation

/// Launch-time cleanup (D§4.4). Its caller (M4's `AppEnvironment`) runs it at utility priority,
/// after the first frame and only once the Reconciler has finished. It never touches the folder
/// of a non-terminal request, and never touches `Logs/`.
struct Janitor: Sendable {
  struct Thresholds: Sendable {
    /// Terminal request folders older than this are removed.
    var requestAge: TimeInterval = 3600
    /// Unreferenced images modified more recently than this are kept (a move-then-save may be in progress).
    var imageFreshness: TimeInterval = 600
    /// Thumbnails above this are trimmed, least recently used first.
    var thumbnailCap: Int64 = 300 * 1024 * 1024
  }

  struct Report: Sendable, Equatable {
    var staging = 0
    var requests = 0
    var images = 0
    var thumbnails = 0
    var bytesFreed: Int64 = 0
    var failures = 0
    var firstError: String?
  }

  let files: FileStore
  let store: DataStore
  let log: ActivityLog
  var thresholds = Thresholds()
  var clock: @Sendable () -> Date = { Date() }

  @concurrent
  func run() async -> Report {
    let started = ContinuousClock.now
    let action = log.begin(
      "Janitor", origin: .system,
      "requests \(Self.duration(thresholds.requestAge)) · images \(Self.duration(thresholds.imageFreshness)) · thumbnails \(thresholds.thumbnailCap / 1_048_576) MB"
    )
    var report = Report()
    var outcome = ActivityOutcome.failed
    var summary: ActivityMessage = "unknown error"
    defer { log.result(action, outcome, summary) }

    let snapshot: JanitorSnapshot
    do {
      snapshot = try await store.janitorSnapshot()
    } catch {
      summary = "in \(Self.seconds(since: started)) · store unavailable: \(error.localizedDescription)"
      return report
    }
    let now = clock()

    // Staging: everything.
    for item in Self.children(of: files.stagingDir) {
      remove(item, counting: \.staging, into: &report)
    }

    // Requests: folders with no record, and terminal ones older than the threshold.
    for dir in Self.children(of: files.requestsDir) {
      if let id = UUID(uuidString: dir.lastPathComponent), let info = snapshot.requests[id] {
        guard info.isTerminal, now.timeIntervalSince(info.finishedOrCreatedAt) > thresholds.requestAge else { continue }
      }
      remove(dir, counting: \.requests, into: &report)
    }

    // Images: unreferenced files, unless modified recently. Nothing outside Images/ is scanned.
    removeOrphanImages(referenced: snapshot.referencedPaths, now: now, &report)

    // Thumbnails: trim to the cap, least recently used first.
    trimThumbnails(&report)

    let removed = "staging \(report.staging) · requests \(report.requests) · images \(report.images) · thumbnails \(report.thumbnails) · \(Self.mb(report.bytesFreed)) freed"
    if report.failures == 0 {
      outcome = .success
      summary = "in \(Self.seconds(since: started)) · \(removed)"
    } else {
      summary = "in \(Self.seconds(since: started)) · \(removed) · \(report.failures) failed: \(report.firstError ?? "unknown")"
    }
    return report
  }

  private func removeOrphanImages(referenced: Set<String>, now: Date, _ report: inout Report) {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    guard let e = FileManager.default.enumerator(at: files.imagesDir, includingPropertiesForKeys: Array(keys)) else { return }
    for case let file as URL in e {
      guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true,
        let path = files.relativePath(of: file), !referenced.contains(path)
      else { continue }
      if let modified = v.contentModificationDate, now.timeIntervalSince(modified) < thresholds.imageFreshness { continue }
      remove(file, counting: \.images, into: &report)
    }
  }

  private func trimThumbnails(_ report: inout Report) {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
    var thumbs: [(url: URL, size: Int64, used: Date)] = []
    for file in Self.children(of: files.thumbnailsDir) {
      guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
      let used = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
      thumbs.append((file, Int64(v.fileSize ?? 0), used))
    }
    var total = thumbs.reduce(0) { $0 + $1.size }
    guard total > thresholds.thumbnailCap else { return }
    for thumb in thumbs.sorted(by: { $0.used < $1.used }) where total > thresholds.thumbnailCap {
      let before = report.thumbnails
      remove(thumb.url, counting: \.thumbnails, into: &report)
      if report.thumbnails > before { total -= thumb.size }
    }
  }

  private func remove(_ url: URL, counting folder: WritableKeyPath<Report, Int>, into report: inout Report) {
    var r = DeletionResult()
    files.remove(url, into: &r)
    report[keyPath: folder] += r.filesRemoved
    report.bytesFreed += r.bytesFreed
    report.failures += r.failures
    report.firstError = report.firstError ?? r.firstError
  }

  private static func children(of dir: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
  }

  static func mb(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  static func duration(_ t: TimeInterval) -> String {
    t >= 3600 && t.truncatingRemainder(dividingBy: 3600) == 0 ? "\(Int(t / 3600)) h" : "\(Int(t / 60)) min"
  }

  static func seconds(since start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    return String(format: "%.1f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
  }
}
