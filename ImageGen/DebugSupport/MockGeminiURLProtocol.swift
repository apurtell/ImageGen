#if DEBUG
import Foundation

/// In-process mock transport handler intercepting Gemini API requests for deterministic testing and preview environments.
///
/// Simulates endpoints including `generateContent`, model catalog queries, and safety filter rejections.
/// Synthesizes valid response payloads with configurable latency, streaming chunk delivery, and multi-request state transitions.
final class MockGeminiURLProtocol: URLProtocol, @unchecked Sendable {
  /// Synchronized global state tracking active mock scenario configuration, synthetic latency, and invocation counts.
  private static let state = Locked<(scenario: LaunchOptions.Scenario, latency: Double, generateCount: Int)>((.success, 2, 0))

  /// Configures mock protocol behavior with the target scenario and latency profile.
  static func configure(scenario: LaunchOptions.Scenario, latency: Double) {
    state.withLock { $0 = (scenario, latency, 0) }
  }

  /// Intercepts requests targeting Gemini API endpoint hosts.
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == GeminiEndpoint.baseURL.host
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Thread-safe cancellation flag set upon request termination.
  private let stopped = Locked(false)

  /// Dispatches mock response delivery after the configured synthetic latency period, streaming chunks to simulate network transfer.
  override func startLoading() {
    let body = Self.readBody(request)
    let path = request.url?.path ?? ""
    let (scenario, latency, count): (LaunchOptions.Scenario, Double, Int) = Self.state.withLock { s in
      if path.hasSuffix(":generateContent") { s.generateCount += 1 }
      return (s.scenario, s.latency, s.generateCount)
    }
    let response = path.hasSuffix(":generateContent")
      ? Self.generate(body: body, scenario: scenario, count: count) : Self.models(path: path, scenario: scenario)
    let url = request.url!
    let deliver: @Sendable () -> Void = { [self] in
      guard !stopped.value else { return }
      let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
      let chunk = max(1, response.body.count / 4)
      var offset = 0
      while offset < response.body.count {
        guard !stopped.value else { return }
        client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<min(offset + chunk, response.body.count)))
        offset += chunk
      }
      guard !stopped.value else { return }
      client?.urlProtocolDidFinishLoading(self)
    }
    let delay = path.hasSuffix(":generateContent") ? latency : min(latency, 0.5)
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
  }

  override func stopLoading() {
    stopped.withLock { $0 = true }
  }

  /// Synthesizes generation response payloads corresponding to the active scenario, echoing requested configuration parameters.
  private static func generate(body: Data, scenario: LaunchOptions.Scenario, count: Int) -> (status: Int, body: Data) {
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let config = (json["generationConfig"] as? [String: Any])?["imageConfig"] as? [String: String]
    let aspect = config?["aspectRatio"].flatMap(AspectRatio.init(rawValue:))
    let size = config?["imageSize"].flatMap(ImageSize.init(rawValue:))
    let parts = ((json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
    let prompt = parts.compactMap { $0["text"] as? String }.last ?? "(no prompt)"
    let categories = (json["safetySettings"] as? [[String: String]])?.compactMap { $0["category"] } ?? []

    func image(_ aspect: AspectRatio?, _ size: ImageSize?) -> [String: Any] {
      let (w, h) = MockImageSizes.size(aspect: aspect, size: size)
      let caption = "\(aspect?.rawValue ?? "default") · \(size?.rawValue ?? "default") · \(w)×\(h)"
      let jpeg = MockImageRenderer.jpeg(width: w, height: h, prompt: prompt, caption: caption)
      return ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }
    func candidate(_ parts: [[String: Any]]?, finish: String, message: String? = nil) -> Data {
      var c: [String: Any] = ["index": 0, "finishReason": finish]
      if let parts { c["content"] = ["role": "model", "parts": parts] }
      if let message { c["finishMessage"] = message }
      return encode(["candidates": [c], "modelVersion": "gemini-3.1-flash-image", "responseId": "mock-\(count)"])
    }
    let success = { candidate([["text": "Mock image for “\(prompt)”."], image(aspect, size)], finish: "STOP") }

    switch scenario {
    case .success: return (200, success())
    case .textOnly: return (200, candidate([["text": "Mock: a text-only reply about “\(prompt)”."]], finish: "STOP"))
    case .twoImages: return (200, candidate([image(aspect, size), image(aspect, size)], finish: "STOP"))
    case .promptRefused: return (200, encode(["promptFeedback": ["blockReason": "PROHIBITED_CONTENT"]]))
    case .imageSafety: return (200, candidate(nil, finish: "IMAGE_SAFETY", message: "Mock: image blocked by safety filter"))
    case .imageSafetyThenSuccess:
      return count == 1 ? (200, candidate(nil, finish: "IMAGE_SAFETY", message: "Mock: image blocked by safety filter")) : (200, success())
    case .imageOther: return (200, candidate(nil, finish: "IMAGE_OTHER"))
    case .empty: return (200, encode(["candidates": [Any]()]))
    case .malformed: return (200, Data(#"{"candidates": [{"content": {"parts": [{"text": "trunc"#.utf8))
    case .rateLimitThenSuccess:
      return count == 1
        ? (429, error(429, "RESOURCE_EXHAUSTED", "Mock: quota exceeded", details: [
          ["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "2s"]
        ])) : (200, success())
    case .badRequest: return (400, error(400, "INVALID_ARGUMENT", "Mock: bad request"))
    case .notFound: return (404, error(404, "NOT_FOUND", "Mock: model not found"))
    case .keyRejected: return keyRejected()
    case .civicRejectedOnce:
      if categories.contains(HarmCategory.civicIntegrity.rawValue) {
        return (400, error(400, "INVALID_ARGUMENT", "Invalid value at 'safety_settings[4].category', \"HARM_CATEGORY_CIVIC_INTEGRITY\""))
      }
      return (200, success())
    case .lowRes: return (200, candidate([image(aspect, .s1K)], finish: "STOP"))
    case .wrongAspect: return (200, candidate([image(.r1x1, size)], finish: "STOP"))
    }
  }

  /// Synthesizes model catalog listing and retrieval responses.
  private static func models(path: String, scenario: LaunchOptions.Scenario) -> (status: Int, body: Data) {
    if scenario == .keyRejected { return keyRejected() }
    func model(_ id: String, _ name: String) -> [String: Any] {
      ["name": "models/\(id)", "displayName": name, "supportedGenerationMethods": ["generateContent", "countTokens"]]
    }
    let all = [
      model("gemini-3.1-flash-image", "Gemini 3.1 Flash Image"), model("gemini-3-pro-image", "Gemini 3 Pro Image"),
      model("gemini-nano-banana-2.1", "Nano Banana 2.1"),
    ]
    if path.hasSuffix("/models") { return (200, encode(["models": all])) }
    let id = path.split(separator: "/").last.map(String.init) ?? ""
    if let found = all.first(where: { ($0["name"] as? String) == "models/\(id)" }) { return (200, encode(found)) }
    return (404, error(404, "NOT_FOUND", "Mock: models/\(id) is not found"))
  }

  /// Synthesizes an API key rejection error response.
  private static func keyRejected() -> (status: Int, body: Data) {
    (400, error(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.", details: [
      ["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID", "domain": "googleapis.com"]
    ]))
  }

  private static func error(_ code: Int, _ status: String, _ message: String, details: [[String: Any]] = []) -> Data {
    encode(["error": ["code": code, "status": status, "message": message, "details": details]])
  }

  private static func encode(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  /// Extracts raw request body data from either in-memory buffers or stream sources.
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
#endif
