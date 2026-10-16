import Foundation
import ImageIO
import Testing

@Suite
struct TestSupportTests {
  @Test(.tags(.io)) func mockURLProtocolServesQueueInOrder() async throws {
    let token = MockURLProtocol.makeToken()
    defer { MockURLProtocol.reset(token: token) }
    let url = URL(string: "https://example.test/v1beta/models/x:generateContent")!
    MockURLProtocol.register(
      [
        .init(status: 429, headers: ["Retry-After": "2"], body: Data("first".utf8)),
        .init(status: 200, bodyChunks: [Data("sec".utf8), Data("ond".utf8)], delay: .milliseconds(20)),
      ], for: url, token: token)
    let session = URLSession(configuration: MockURLProtocol.configuration())
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(token, forHTTPHeaderField: MockURLProtocol.tokenHeader)
    let (d1, r1) = try await session.upload(for: request, from: Data("body-1".utf8))
    let (d2, r2) = try await session.upload(for: request, from: Data("body-2".utf8))

    #expect((r1 as? HTTPURLResponse)?.statusCode == 429)
    #expect((r1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") == "2")
    #expect(String(decoding: d1, as: UTF8.self) == "first")
    #expect((r2 as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: d2, as: UTF8.self) == "second")
    let recorded = MockURLProtocol.recorded(token: token)
    #expect(recorded.map { String(decoding: $0.body, as: UTF8.self) } == ["body-1", "body-2"])

    // The queue is empty now: a third request fails.
    await #expect(throws: URLError.self) { _ = try await session.upload(for: request, from: Data()) }
  }

  @Test(.tags(.io)) func testFileRootIsRemoved() throws {
    var root: TestFileRoot? = TestFileRoot()
    let url = try #require(root?.url)
    try Data("x".utf8).write(to: root!.file("a/b.txt"))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("a/b.txt").path))
    root = nil
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test(.tags(.io), arguments: [
    ("sample.heic", 300_000), ("rotated_exif6.jpg", 100_000), ("tiny_16x9.png", 2_000),
    ("tiny_square.jpg", 2_000),
  ])
  func fixtureImagesDecode(name: String, maxBytes: Int) throws {
    let data = try FixtureLoader.data("Images/\(name)")
    #expect(data.count <= maxBytes)
    let info = try #require(ImageFactory.inspect(data))
    switch name {
    case "rotated_exif6.jpg":
      #expect(info.orientation == 6)
      #expect((info.width, info.height) == (400, 300))
    case "tiny_16x9.png": #expect((info.width, info.height) == (32, 18))
    case "tiny_square.jpg": #expect((info.width, info.height) == (16, 16))
    default: #expect(info.width > 0)
    }
  }

  @Test(.tags(.pure)) func imageFactoryMakesEveryFormat() throws {
    #expect(ImageFactory.inspect(ImageFactory.jpeg(orientation: 6, gps: true))?.orientation == 6)
    #expect(ImageFactory.inspect(ImageFactory.png(alpha: true)) != nil)
    #expect(ImageFactory.inspect(ImageFactory.heic(alpha: true)) != nil)
    #expect(ImageFactory.inspect(ImageFactory.gif()) != nil)
  }
}
