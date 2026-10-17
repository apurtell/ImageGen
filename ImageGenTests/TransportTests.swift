import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.integration))
struct TransportTests {
  /// Test fixture configuring a URLSessionTransport on an isolated temporary root using mock network protocols.
  final class Rig: Sendable {
    let root = TestFileRoot()
    let files: FileStore
    let token = MockURLProtocol.makeToken()
    let sleeper = ManualSleeper()
    let transport: URLSessionTransport

    init() {
      files = FileStore(root: root.url.appendingPathComponent("ImageGen"), cachesRoot: root.url.appendingPathComponent("Caches"))
      let token = self.token
      let sleeper = self.sleeper
      transport = URLSessionTransport(
        configuration: MockURLProtocol.configuration(), files: files, sleeper: { await sleeper.sleep($0) },
        requestDecorator: { $0.setValue(token, forHTTPHeaderField: MockURLProtocol.tokenHeader) })
    }

    deinit {
      transport.invalidateAndWait()
      MockURLProtocol.reset(token: token)
    }

    func job(_ id: UUID = UUID(), attempt: Int = 1, body: Data = Data("{\"contents\":[]}".utf8), earliestBegin: Date? = nil) throws -> TransportJob {
      let url = files.bodyURL(id)
      try FileStore.createDirectory(url.deletingLastPathComponent())
      try body.write(to: url)
      return TransportJob(
        requestID: id, attempt: attempt, modelID: ModelCatalog.defaultModelID, bodyURL: url, bodySize: body.count,
        expectedReceiveBytes: 1_000_000, earliestBegin: earliestBegin)
    }

    func respond(_ responses: [MockURLProtocol.Response]) {
      MockURLProtocol.register(responses, for: GenerationHarness.flashURL, token: token)
    }

    /// Awaits and returns the next transport event from the stream iterator.
    func next(_ iterator: inout AsyncStream<TransportEvent>.Iterator) async -> TransportEvent? {
      await iterator.next()
    }
  }

  static func completion(_ e: TransportEvent?) -> TransportCompletion? {
    if case .completed(let c)? = e { return c }
    return nil
  }

  @Test func chunkedBodyAccumulatesInOrder() async throws {
    let rig = Rig()
    let chunks = (0..<5).map { Data("chunk-\($0);".utf8) }
    rig.respond([.init(status: 200, bodyChunks: chunks)])
    let job = try rig.job()
    _ = try rig.transport.start(job, apiKey: "k")
    var it = rig.transport.events.makeAsyncIterator()
    let c = try #require(Self.completion(await it.next()))
    #expect(try String(contentsOf: c.partURL, encoding: .utf8) == "chunk-0;chunk-1;chunk-2;chunk-3;chunk-4;")
    #expect(c.bytesReceived == chunks.reduce(0) { $0 + $1.count })
    #expect(c.partURL == rig.files.partURL(job.requestID, attempt: 1))
  }

  @Test func bodySplitAcrossRecreatedAccumulatorAppends() throws {
    let root = TestFileRoot()
    let files = FileStore(root: root.url, cachesRoot: root.url)
    let id = UUID()
    let first = ResponseAccumulator(files: files)
    try first.prepareNewAttempt(requestID: id, attempt: 1)
    first.append(Data("a".utf8), requestID: id, attempt: 1, taskIdentifier: 7)
    first.append(Data("b".utf8), requestID: id, attempt: 1, taskIdentifier: 7)
    // Simulates process restart where a new accumulator instance resumes chunk assembly for an active task.
    let second = ResponseAccumulator(files: files)
    for s in ["c", "d", "e"] { second.append(Data(s.utf8), requestID: id, attempt: 1, taskIdentifier: 7) }
    let (url, bytes) = second.complete(requestID: id, attempt: 1, taskIdentifier: 7, httpStatus: 200)
    #expect(try String(contentsOf: url, encoding: .utf8) == "abcde")
    #expect(bytes == 5)
    #expect(ResponseAccumulator.markerStatus(files.completeMarkerURL(id, attempt: 1)) == 200)
  }

  @Test func newAttemptStartsEmptyPartFile() throws {
    let root = TestFileRoot()
    let files = FileStore(root: root.url, cachesRoot: root.url)
    let id = UUID()
    let acc = ResponseAccumulator(files: files)
    try acc.prepareNewAttempt(requestID: id, attempt: 1)
    acc.append(Data("old".utf8), requestID: id, attempt: 1, taskIdentifier: 1)
    _ = acc.complete(requestID: id, attempt: 1, taskIdentifier: 1, httpStatus: 503)
    try acc.prepareNewAttempt(requestID: id, attempt: 2)
    #expect(try Data(contentsOf: files.partURL(id, attempt: 2)).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: files.completeMarkerURL(id, attempt: 2).path))
    #expect(try String(contentsOf: files.partURL(id, attempt: 1), encoding: .utf8) == "old")
  }

  @Test func statusAndHeadersCaptured() async throws {
    let rig = Rig()
    rig.respond([.init(status: 429, headers: ["Retry-After": "7", "X-Other": "1"], body: Data("{}".utf8))])
    _ = try rig.transport.start(try rig.job(), apiKey: "k")
    var it = rig.transport.events.makeAsyncIterator()
    let c = try #require(Self.completion(await it.next()))
    #expect(c.httpStatus == 429)
    #expect(c.headers["Retry-After"] == "7")
    #expect(c.error == nil)
    #expect(c.attempt == 1)
  }

  @Test func completeMarkerWrittenBeforeCompletedEvent() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data("{\"candidates\":[]}".utf8))])
    let job = try rig.job()
    _ = try rig.transport.start(job, apiKey: "k")
    var it = rig.transport.events.makeAsyncIterator()
    _ = try #require(Self.completion(await it.next()))
    #expect(FileManager.default.fileExists(atPath: rig.files.completeMarkerURL(job.requestID, attempt: 1).path))
    #expect(ResponseAccumulator.markerStatus(rig.files.completeMarkerURL(job.requestID, attempt: 1)) == 200)
  }

  @Test func cancelReasonCarried() async throws {
    // Validates background task cancellation reason extraction from delegate error userInfo dictionaries.
    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorCancelled,
      userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication])
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data(), delay: .seconds(5))])
    let job = try rig.job()
    let task = try rig.transport.start(job, apiKey: "k")
    // Simulates system cancellation dispatch emitted by URLSession following application termination.
    let session = URLSession(configuration: .ephemeral)
    let fake = session.dataTask(with: URLRequest(url: GenerationHarness.flashURL))
    fake.taskDescription = TaskDescription.make(requestID: job.requestID, attempt: 1)
    rig.transport.urlSession(session, task: fake, didCompleteWithError: error)
    var it = rig.transport.events.makeAsyncIterator()
    let c = try #require(Self.completion(await it.next()))
    #expect(c.error == .cancelled)
    #expect(c.cancelReason == NSURLErrorCancelledReasonUserForceQuitApplication)
    #expect(task > 0)
  }

  @Test func eventsBufferedBeforeConsumerStarts() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data("{}".utf8))])
    _ = try rig.transport.start(try rig.job(), apiKey: "k")
    // Verifies that transport stream events buffer successfully prior to consumer subscription.
    try await Task.sleep(for: .milliseconds(300))
    var it = rig.transport.events.makeAsyncIterator()
    #expect(Self.completion(await it.next())?.httpStatus == 200)
  }

  @Test func finishedEventsAfterBackToBackCompletion() async throws {
    let rig = Rig()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: URLRequest(url: GenerationHarness.flashURL))
    task.taskDescription = TaskDescription.make(requestID: UUID(), attempt: 1)
    rig.transport.urlSession(session, task: task, didCompleteWithError: nil)
    rig.transport.urlSessionDidFinishEvents(forBackgroundURLSession: session)
    var it = rig.transport.events.makeAsyncIterator()
    #expect(Self.completion(await it.next()) != nil)
    #expect(await it.next() == .finishedEvents(sessionIdentifier: ""))
  }

  @Test func deferredResumeHonorsEarliestBegin() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data("{}".utf8))])
    let job = try rig.job(earliestBegin: Date().addingTimeInterval(30))
    let id = try rig.transport.start(job, apiKey: "k")
    var it = rig.transport.events.makeAsyncIterator()
    try await Task.sleep(for: .milliseconds(200))
    #expect(MockURLProtocol.recorded(token: rig.token).isEmpty)
    #expect(rig.sleeper.requested.first.map { $0 > .seconds(29) && $0 <= .seconds(30) } == true)
    #expect(await rig.transport.liveTasks().map(\.taskIdentifier) == [id])
    rig.sleeper.advance()
    #expect(await it.next() == .began(requestID: job.requestID, attempt: 1, taskIdentifier: id))
    #expect(Self.completion(await it.next())?.httpStatus == 200)
    #expect(MockURLProtocol.recorded(token: rig.token).count == 1)
  }

  @Test func cancelledDeferredTaskCompletesCancelled() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data("{}".utf8))])
    let job = try rig.job(earliestBegin: Date().addingTimeInterval(30))
    _ = try rig.transport.start(job, apiKey: "k")
    await rig.transport.cancel(requestID: job.requestID)
    var it = rig.transport.events.makeAsyncIterator()
    #expect(Self.completion(await it.next())?.error == .cancelled)
    rig.sleeper.advance()
    #expect(MockURLProtocol.recorded(token: rig.token).isEmpty)
  }

  @Test func emptyBody200Reported() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data())])
    _ = try rig.transport.start(try rig.job(), apiKey: "k")
    var it = rig.transport.events.makeAsyncIterator()
    let c = try #require(Self.completion(await it.next()))
    #expect(c.httpStatus == 200)
    #expect(c.bytesReceived == 0)
    #expect(FileManager.default.fileExists(atPath: c.partURL.path))
  }

  @Test func uploadBodyBytesEqualBodyFile() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data("{}".utf8))])
    let body = Data(String(repeating: "x", count: 200_000).utf8)
    _ = try rig.transport.start(try rig.job(body: body), apiKey: "k")
    var it = rig.transport.events.makeAsyncIterator()
    _ = await it.next()
    #expect(MockURLProtocol.recorded(token: rig.token).first?.body == body)
  }

  @Test func headerKeyPresentAndNoKeyInURL() async throws {
    let rig = Rig()
    rig.respond([.init(status: 200, body: Data("{}".utf8))])
    _ = try rig.transport.start(try rig.job(), apiKey: "AIza-secret")
    var it = rig.transport.events.makeAsyncIterator()
    _ = await it.next()
    let request = try #require(MockURLProtocol.recorded(token: rig.token).first?.request)
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-secret")
    #expect(request.url?.absoluteString.contains("key=") == false)
    #expect(request.httpMethod == "POST")
  }
}

@Suite(.tags(.pure))
struct BackgroundConfigTests {
  let c = URLSessionTransport.backgroundConfiguration(bundleID: "com.andrewpurtell.imagegen")

  @Test func identifier() { #expect(c.identifier == "com.andrewpurtell.imagegen.generation") }
  @Test func notDiscretionary() { #expect(!c.isDiscretionary) }
  @Test func sendsLaunchEvents() { #expect(c.sessionSendsLaunchEvents) }
  @Test func idleTimeout300() { #expect(c.timeoutIntervalForRequest == 300) }
  @Test func resourceTimeout1800() { #expect(c.timeoutIntervalForResource == 1800) }
  @Test func fourConnectionsPerHost() { #expect(c.httpMaximumConnectionsPerHost == 4) }
  @Test func reloadIgnoringCache() { #expect(c.requestCachePolicy == .reloadIgnoringLocalCacheData) }
  @Test func noURLCache() { #expect(c.urlCache == nil) }
  @Test func waitsForConnectivityNotSet() {
    // Preserves platform default: background URL sessions inherently wait for connectivity regardless of configuration.
    #expect(c.waitsForConnectivity == URLSessionConfiguration.background(withIdentifier: "x").waitsForConnectivity)
  }
}
