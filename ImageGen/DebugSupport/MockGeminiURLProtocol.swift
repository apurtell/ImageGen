#if DEBUG
import Foundation

/// Answers the Gemini API in code for DEBUG mock mode (plan §2.6), so the simulator needs no key
/// or network. `generateContent` returns a JPEG at the `MockImageSizes` size for the request's
/// `imageConfig`, in a real response shape; `GET models` lists Flash, 3 Pro and 2.1.
///
/// How it works: a `URLProtocol` subclass is a fake server inside the system's URL loading system.
/// A session whose configuration lists this class in `protocolClasses` asks `canInit` about each
/// request. For a Gemini request, the system creates one instance of this class and calls
/// `startLoading`. The instance then reports a response, the body data and the end through its
/// `client`, as a real connection would. The app's code above the session cannot see the difference.
///
/// Place in the design: only `DebugHooks` uses this class, for `-UITestMockGemini 1`. It registers the
/// class on an *ephemeral* transport configuration and on the models session. A background session
/// runs its transfers in a system process, which does not use the app's protocol classes, so mock mode
/// replaces the background session with an ephemeral one.
///
/// Concurrency: the system calls `startLoading` and `stopLoading` on its own loading thread, and this
/// class delivers the response later on a global dispatch queue. So two threads can touch an instance.
/// `stopped` (one for each instance) and `state` (one for the class) are `Locked` values; nothing
/// else changes after creation.
///
/// `@unchecked Sendable`: `URLProtocol` can't be checked; the only shared state is the `Locked` config.
/// Within one instance, the `stopped` flag is also `Locked`. See the primer, *`Sendable`*.
final class MockGeminiURLProtocol: URLProtocol, @unchecked Sendable {
  /// The scenario and latency from the launch options, and the number of `generateContent` requests
  /// so far. The count drives the "…ThenSuccess" scenarios: the first request fails or is refused, and
  /// later ones succeed.
  private static let state = Locked<(scenario: LaunchOptions.Scenario, latency: Double, generateCount: Int)>((.success, 2, 0))

  /// Called once at launch, before any session exists. It also resets the request count.
  static func configure(scenario: LaunchOptions.Scenario, latency: Double) {
    state.withLock { $0 = (scenario, latency, 0) }
  }

  /// Takes every request to the Gemini host and nothing else.
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == GeminiEndpoint.baseURL.host
  }

  /// Required by `URLProtocol`. The request is used as it is.
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Set by `stopLoading` (a cancel, for example a Stop from the user). It can change while a delivery
  /// runs on another thread, so it is `Locked`.
  private let stopped = Locked(false)

  /// Builds the whole response at once, then delivers it after the configured latency. The latency
  /// keeps the pending card on screen long enough to test and to capture.
  override func startLoading() {
    let body = Self.readBody(request)
    let path = request.url?.path ?? ""
    // One lock call reads the configuration and counts this request, so two requests that start at the
    // same time get different counts.
    let (scenario, latency, count): (LaunchOptions.Scenario, Double, Int) = Self.state.withLock { s in
      if path.hasSuffix(":generateContent") { s.generateCount += 1 }
      return (s.scenario, s.latency, s.generateCount)
    }
    let response = path.hasSuffix(":generateContent")
      ? Self.generate(body: body, scenario: scenario, count: count) : Self.models(path: path, scenario: scenario)
    let url = request.url!
    // `[self]` captures the instance strongly on purpose: it must stay alive until the delivery ends.
    let deliver: @Sendable () -> Void = { [self] in
      // Checked before every call: a Stop can land between chunks, and nothing may reach the
      // client after `stopLoading`. (The check and the call are two steps, so a Stop that lands
      // between them still lets that one call through. The check makes this window small.)
      guard !stopped.value else { return }
      let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
      // A few chunks, as a real response would arrive.
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
    // The models calls wait at most 0.5 s, so a long generation latency does not slow the Settings screens.
    let delay = path.hasSuffix(":generateContent") ? latency : min(latency, 0.5)
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
  }

  override func stopLoading() {
    stopped.withLock { $0 = true }
  }

  // MARK: Responses

  /// The `generateContent` answer for a scenario. It reads the settings from the request body that
  /// the app sent, so the image size and the caption show what the app asked for. The scenarios match
  /// the table in plan §2.6.
  private static func generate(body: Data, scenario: LaunchOptions.Scenario, count: Int) -> (status: Int, body: Data) {
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]  // A body that is not JSON gives the defaults.
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
    // A JSON body cut off in the middle, so the parser's "not a response" rule applies.
    case .malformed: return (200, Data(#"{"candidates": [{"content": {"parts": [{"text": "trunc"#.utf8))
    case .rateLimitThenSuccess:
      return count == 1
        ? (429, error(429, "RESOURCE_EXHAUSTED", "Mock: quota exceeded", details: [
          ["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "2s"]
        ])) : (200, success())
    case .badRequest: return (400, error(400, "INVALID_ARGUMENT", "Mock: bad request"))
    case .notFound: return (404, error(404, "NOT_FOUND", "Mock: model not found"))
    case .keyRejected: return keyRejected()
    // Rejects any body that still has the CIVIC category, so the app's one-time fallback (D§2.4)
    // runs: the retry without the category succeeds.
    case .civicRejectedOnce:
      if categories.contains(HarmCategory.civicIntegrity.rawValue) {
        return (400, error(400, "INVALID_ARGUMENT", "Invalid value at 'safety_settings[4].category', \"HARM_CATEGORY_CIVIC_INTEGRITY\""))
      }
      return (200, success())
    case .lowRes: return (200, candidate([image(aspect, .s1K)], finish: "STOP"))
    case .wrongAspect: return (200, candidate([image(.r1x1, size)], finish: "STOP"))
    }
  }

  /// `models.list` (a path that ends in `/models`) or `models.get` (any other models path). Flash Lite
  /// and 2.5 Flash are left out on purpose, so mock mode shows them as "Not listed for this key".
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

  /// The body the real API returns for a bad key: 400 with the `API_KEY_INVALID` reason.
  private static func keyRejected() -> (status: Int, body: Data) {
    (400, error(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.", details: [
      ["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID", "domain": "googleapis.com"]
    ]))
  }

  private static func error(_ code: Int, _ status: String, _ message: String, details: [[String: Any]] = []) -> Data {
    encode(["error": ["code": code, "status": status, "message": message, "details": details]])
  }

  private static func encode(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()  // The objects are built above and always encode.
  }

  /// The request body, as data or as a stream. An upload from a file can reach a `URLProtocol` as a
  /// stream, so this reads either form.
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
