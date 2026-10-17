import Foundation

/// Background garbage collection orchestrator reconciling disk state with persistent store metadata.
///
/// Architecture:
/// - Executes at low priority following initial application presentation and transport reconciliation.
/// - Performs multi-stage pruning across retired staging artifacts, expired terminal request folders,
///   unreferenced image assets, and LRU thumbnail cache quotas.
/// - Concurrency guarantees: Operates concurrently off the caller's actor context via `@concurrent`.
///   Maintains consistency without file system locks by adopting a conservative ordering strategy:
///   enumerates directory contents prior to acquiring database snapshots, respects freshness grace periods
///   for in-flight transactions, and re-validates request states immediately prior to folder deletion.
struct Janitor: Sendable {
  struct Thresholds: Sendable {
    /// Age cutoff for pruning terminal request attempt directories.
    var requestAge: TimeInterval = 3600
    /// Grace period sparing unreferenced image assets to accommodate multi-stage staging and commit pipelines.
    var imageFreshness: TimeInterval = 600
    /// Maximum disk footprint allocated to thumbnail cache storage.
    var thumbnailCap: Int64 = 300 * 1024 * 1024
  }

  /// Telemetry report detailing reclaimed resources and non-fatal operational errors.
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

  /// Executes an end-to-end cleanup pass concurrently, emitting diagnostic telemetry upon completion.
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

    // Enumerate disk hierarchies prior to acquiring database state to ensure recent writes are captured.
    let retired = Self.children(of: files.retiredStagingDir)
    let requestDirs = Self.children(of: files.requestsDir)
    let images = listImages()

    let snapshot: JanitorSnapshot
    do {
      snapshot = try await store.janitorSnapshot()
    } catch {
      summary = "in \(Self.seconds(since: started)) · store unavailable: \(error.localizedDescription)"
      return report
    }
    let now = clock()

    // 1. Purge retired staging containers accumulated from earlier process runs.
    for dir in retired {
      remove(dir, counting: \.staging, into: &report)
    }

    // 2. Reclaim orphaned or expired terminal request attempt directories.
    for dir in requestDirs {
      let id = UUID(uuidString: dir.lastPathComponent)
      if let id, let info = snapshot.requests[id] {
        guard info.isTerminal, now.timeIntervalSince(info.finishedOrCreatedAt) > thresholds.requestAge else { continue }
      }
      // Re-verify request lifecycle state immediately prior to folder deletion to avoid racing active retries.
      if let id {
        let current: JanitorSnapshot.RequestInfo?
        do { current = try await store.janitorRequestInfo(id) } catch { continue }
        if let current {
          guard current.isTerminal, now.timeIntervalSince(current.finishedOrCreatedAt) > thresholds.requestAge else { continue }
        }
      }
      remove(dir, counting: \.requests, into: &report)
    }

    // 3. Remove unreferenced images outside the freshness protection window.
    removeOrphanImages(images, referenced: snapshot.referencedPaths, now: now, &report)

    // 4. Enforce thumbnail storage quotas via LRU eviction.
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

  /// Structural index of files and directory metadata discovered under `Images/`.
  private struct ImageListing {
    var files: [(url: URL, modified: Date?)] = []
    var folders: [(url: URL, modified: Date)] = []
  }

  private func listImages() -> ImageListing {
    var listing = ImageListing()
    for dir in Self.children(of: files.imagesDir) {
      guard let v = try? dir.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
        v.isDirectory == true, let date = v.contentModificationDate
      else { continue }
      listing.folders.append((dir, date))
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    if let e = FileManager.default.enumerator(at: files.imagesDir, includingPropertiesForKeys: Array(keys)) {
      for case let file as URL in e {
        guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
        listing.files.append((file, v.contentModificationDate))
      }
    }
    return listing
  }

  private func removeOrphanImages(_ listing: ImageListing, referenced: Set<String>, now: Date, _ report: inout Report) {
    for (file, modified) in listing.files {
      guard let path = files.relativePath(of: file), !referenced.contains(path) else { continue }
      if let modified, now.timeIntervalSince(modified) < thresholds.imageFreshness { continue }
      remove(file, counting: \.images, into: &report)
    }
    // Remove empty conversation folders after file pruning, respecting recent modification grace periods.
    for (dir, modified) in listing.folders where now.timeIntervalSince(modified) >= thresholds.imageFreshness {
      _ = rmdir(dir.path)
    }
  }

  /// Trims thumbnail cache files in least-recently-used order until aggregate size conforms to quota.
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

  /// Removes an artifact path and records operational metrics against the designated category.
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
