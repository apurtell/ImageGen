import Foundation
import Synchronization

/// Serves canned responses to requests made through an ephemeral session that lists it in
/// `protocolClasses` (plan §2.2). Each URL has a queue: one response per request, in order.
///
/// State is keyed by a per-test token sent in the `X-Test-Token` header, so suites can run in
/// parallel. Requests without the header use the empty token.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  static let tokenHeader = "X-Test-Token"

  struct Response: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var bodyChunks: [Data] = []
    var delay: Duration = .zero

    init(status: Int, headers: [String: String] = [:], bodyChunks: [Data] = [], delay: Duration = .zero) {
      self.status = status
      self.headers = headers
      self.bodyChunks = bodyChunks
      self.delay = delay
    }

    init(status: Int, headers: [String: String] = [:], body: Data, delay: Duration = .zero) {
      self.init(status: status, headers: headers, bodyChunks: [body], delay: delay)
    }
  }

  struct RecordedRequest: Sendable {
    let request: URLRequest
    /// From `httpBody` or, for upload-from-file bodies, the drained `httpBodyStream`.
    let body: Data
  }

  private struct TokenState {
    var queues: [String: [Response]] = [:]
    var recorded: [RecordedRequest] = []
  }

  private static let registry = Mutex<[String: TokenState]>([:])

  // MARK: Test API

  static func makeToken() -> String { UUID().uuidString }

  /// Appends responses to the queue for `url` (matched on the full URL string).
  static func register(_ responses: [Response], for url: URL, token: String) {
    registry.withLock { r in
      r[token, default: TokenState()].queues[url.absoluteString, default: []].append(contentsOf: responses)
    }
  }

  static func recorded(token: String) -> [RecordedRequest] {
    registry.withLock { $0[token]?.recorded ?? [] }
  }

  static func reset(token: String) {
    _ = registry.withLock { $0.removeValue(forKey: token) }
  }

  /// An ephemeral configuration that routes through this protocol.
  static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return config
  }

  // MARK: URLProtocol

  private let cancelled = Mutex(false)

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
    let body = Self.readBody(request)
    let key = request.url?.absoluteString ?? ""
    let next: Response? = Self.registry.withLock { r in
      var state = r[token, default: TokenState()]
      state.recorded.append(RecordedRequest(request: request, body: body))
      let response = state.queues[key]?.isEmpty == false ? state.queues[key]!.removeFirst() : nil
      r[token] = state
      return response
    }
    guard let next, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    let deliver = { [self] in
      guard !cancelled.withLock({ $0 }) else { return }
      let http = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
      client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
      for chunk in next.bodyChunks where !chunk.isEmpty {
        client?.urlProtocol(self, didLoad: chunk)
      }
      client?.urlProtocolDidFinishLoading(self)
    }
    if next.delay == .zero {
      deliver()
    } else {
      let (s, atto) = next.delay.components
      let seconds = Double(s) + Double(atto) / 1e18
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deliver)
    }
  }

  override func stopLoading() {
    cancelled.withLock { $0 = true }
  }

  private static func readBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = stream.read(&buffer, maxLength: buffer.count)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }
}
