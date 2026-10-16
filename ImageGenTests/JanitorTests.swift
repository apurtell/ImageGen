import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.io))
struct JanitorTests {
  /// A store, a probe log on the same temporary root, and the clock the Janitor and store share.
  struct Fixture {
    let s: InMemoryStore
    let probe: ActivityLogProbe
    var janitor: Janitor

    init(thumbnailCap: Int64 = 300 * 1024 * 1024) throws {
      s = try InMemoryStore()
      probe = ActivityLogProbe(root: s.root)
      let clock = s.clock
      janitor = Janitor(
        files: s.files, store: s.store, log: probe.log,
        thresholds: Janitor.Thresholds(thumbnailCap: thumbnailCap), clock: { clock.now })
    }

    /// Writes a file with the given modification time relative to the clock.
    func write(_ url: URL, bytes: Int = 100, age: TimeInterval) throws {
      try FileStore.createDirectory(url.deletingLastPathComponent())
      try Data(repeating: 7, count: bytes).write(to: url)
      let date = s.clock.now.addingTimeInterval(-age)
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  }

  @Test func emptiesStaging() async throws {
    let f = try Fixture()
    try f.write(f.s.files.stagingURL(UUID(), ext: "jpg"), age: 0)
    try f.write(f.s.files.stagingDir.appendingPathComponent("prepared/x-2048.jpg"), age: 0)
    let report = await f.janitor.run()
    #expect(report.staging == 2)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: f.s.files.stagingDir.path))?.isEmpty ?? true)
  }

  @Test func removesTerminalRequestDirsOlderThan1h() async throws {
    let f = try Fixture()
    let conv = try await f.s.store.createConversation()
    let old = try await f.s.send(conv, prompt: "old")
    let recent = try await f.s.send(conv, prompt: "recent")
    let now = f.s.clock.now
    try await f.s.store.updateRequest(old.requestID) {
      $0.state = .succeeded
      $0.completedAt = now.addingTimeInterval(-7200)
    }
    try await f.s.store.updateRequest(recent.requestID) {
      $0.state = .failed
      $0.completedAt = now.addingTimeInterval(-600)
    }
    let orphan = UUID()
    for id in [old.requestID, recent.requestID, orphan] { try f.write(f.s.files.bodyURL(id), age: 0) }

    let report = await f.janitor.run()
    #expect(!f.exists(f.s.files.requestDir(old.requestID)))
    #expect(!f.exists(f.s.files.requestDir(orphan)))
    #expect(f.exists(f.s.files.bodyURL(recent.requestID)))
    #expect(report.requests == 2)
  }

  @Test func keepsLiveRequestDirs() async throws {
    let f = try Fixture()
    let conv = try await f.s.store.createConversation()
    let live = try await f.s.send(conv, prompt: "live")
    try await f.s.store.updateRequest(live.requestID) { $0.state = .inFlight }
    f.s.clock.advance(86_400)
    let out = f.s.files.outputDir(live.requestID, attempt: 1).appendingPathComponent("x.png")
    try f.write(f.s.files.bodyURL(live.requestID), age: 86_400)
    try f.write(f.s.files.partURL(live.requestID, attempt: 1), age: 86_400)
    try f.write(out, age: 86_400)
    let report = await f.janitor.run()
    #expect(report.requests == 0)
    #expect(f.exists(f.s.files.bodyURL(live.requestID)))
    #expect(f.exists(out))
  }

  @Test func removesOrphanImages() async throws {
    let f = try Fixture()
    let conv = UUID()
    let orphan = f.s.files.imageURL(conv: conv, image: UUID(), ext: "png")
    let orphanPrepared = f.s.files.preparedURL(conv: conv, image: UUID(), edge: 2048, ext: "jpg")
    try f.write(orphan, bytes: 2048, age: 3600)
    try f.write(orphanPrepared, bytes: 1024, age: 3600)
    let report = await f.janitor.run()
    #expect(!f.exists(orphan))
    #expect(!f.exists(orphanPrepared))
    #expect(report.images == 2)
    #expect(report.bytesFreed == 3072)
  }

  @Test func keepsPreparedFilesReferencedByAssets() async throws {
    let f = try Fixture()
    let conv = try await f.s.store.createConversation()
    let a = try f.s.stage()
    let record = try await f.s.send(conv, prompt: "x", attachments: [a])
    // A reused model output recorded only as a request input is kept too.
    let reused = f.s.files.imageURL(conv: conv, image: UUID(), ext: "png")
    try f.write(reused, age: 3600)
    try await f.s.store.updateRequest(record.requestID) { [path = f.s.files.relativePath(of: reused)!] in
      $0.inputs = [RequestInput(imageID: UUID(), preparedRelativePath: path, mimeType: "image/png", byteCount: 100, pixelWidth: 1, pixelHeight: 1)]
    }
    f.s.clock.advance(3600)
    let snap = try #require(try await f.s.store.imageSnapshots(messageID: record.userMessageID).first)
    let report = await f.janitor.run()
    #expect(report.images == 0)
    #expect(f.exists(f.s.files.url(relative: snap.originalRelativePath)))
    #expect(f.exists(f.s.files.url(relative: try #require(snap.prepared).preparedRelativePath)))
    #expect(f.exists(reused))
  }

  @Test func skipsFreshUnreferencedImages() async throws {
    let f = try Fixture()
    let fresh = f.s.files.imageURL(conv: UUID(), image: UUID(), ext: "png")
    let stale = f.s.files.imageURL(conv: UUID(), image: UUID(), ext: "png")
    try f.write(fresh, age: 9 * 60)
    try f.write(stale, age: 11 * 60)
    _ = await f.janitor.run()
    #expect(f.exists(fresh))
    #expect(!f.exists(stale))
  }

  @Test func scansOnlyImagesFolder() async throws {
    let f = try Fixture()
    let elsewhere = f.s.files.root.appendingPathComponent("Other/stray.png")
    let store = f.s.files.root.appendingPathComponent("default.store")
    try f.write(elsewhere, age: 86_400)
    try f.write(store, age: 86_400)
    let report = await f.janitor.run()
    #expect(f.exists(elsewhere))
    #expect(f.exists(store))
    #expect(report.images == 0)
  }

  @Test func trimsThumbnailCacheLRU() async throws {
    let f = try Fixture(thumbnailCap: 3000)
    let thumbs = (0..<5).map { _ in f.s.files.thumbnailsDir.appendingPathComponent("\(UUID().uuidString)-240.jpg") }
    for (i, url) in thumbs.enumerated() {
      // thumbs[0] is the least recently used.
      try f.write(url, bytes: 1000, age: TimeInterval(1000 - i * 100))
      var values = URLResourceValues()
      values.contentAccessDate = f.s.clock.now.addingTimeInterval(-TimeInterval(1000 - i * 100))
      var u = url
      try? u.setResourceValues(values)
    }
    let report = await f.janitor.run()
    #expect(report.thumbnails == 2)
    #expect(thumbs.map(f.exists) == [false, false, true, true, true])
  }

  @Test func neverTouchesLogs() async throws {
    let f = try Fixture()
    let other = f.s.files.logsDir.appendingPathComponent("old.jsonl")
    try f.write(other, age: 86_400 * 30)
    f.probe.log.result(f.probe.log.begin("Copy", origin: .user, ""), .success, "")
    _ = await f.janitor.run()
    #expect(f.exists(other))
    #expect(f.exists(f.probe.fileURL))
  }

  @Test func runLogged() async throws {
    let f = try Fixture()
    try f.write(f.s.files.stagingURL(UUID(), ext: "jpg"), bytes: 1_048_576, age: 0)
    try f.write(f.s.files.imageURL(conv: UUID(), image: UUID(), ext: "png"), bytes: 524_288, age: 3600)
    _ = await f.janitor.run()
    let tree = await f.probe.action(named: "Janitor")
    #expect(tree.count == 2)
    let begin = try #require(tree.first)
    #expect(begin.origin == .system)
    #expect(begin.message == "requests 1 h · images 10 min · thumbnails 300 MB")
    let result = try #require(tree.last)
    #expect(result.outcome == .success)
    #expect(result.message.hasPrefix("in "))
    #expect(result.message.contains("staging 1 · requests 0 · images 1 · thumbnails 0 · 1.5 MB freed"))
    await f.probe.assertPaired()
  }

  @Test func failedRemovalEndsFailed() async throws {
    let f = try Fixture()
    let locked = f.s.files.stagingDir.appendingPathComponent("locked")
    try f.write(locked.appendingPathComponent("inner.jpg"), age: 0)
    // A read-only folder can't have its contents removed.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let report = await f.janitor.run()
    #expect(report.failures == 1)
    let result = try #require(await f.probe.action(named: "Janitor").last)
    #expect(result.outcome == .failed)
    #expect(result.message.contains("1 failed:"))
  }
}
