import Foundation

/// One entry of `models.list`, or the result of `models.get`. Only the fields the app uses are decoded.
struct ModelInfo: Sendable, Equatable, Decodable {
  /// `models/<id>`.
  let name: String
  let displayName: String?
  let supportedGenerationMethods: [String]?

  /// The bare model ID, as the catalog and `generateContent` use it.
  var id: String { name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name }
  var supportsGenerateContent: Bool { supportedGenerationMethods?.contains("generateContent") == true }
}

/// The failures that the key and model screens show. Each case maps to one kind of message.
enum ModelsClientError: Error, Equatable {
  /// 400 `API_KEY_INVALID`, 401 or 403.
  case keyRejected(status: Int, apiStatus: String?, reason: String?, message: String)
  /// A network error or a 5xx.
  case unreachable(String)
  case notFound(String)
  case http(status: Int, message: String)
  case malformed
}

/// `models.list` and `models.get` (D§2.5, D§3.2) on an ephemeral session with a 20 s timeout.
///
/// Place in the design: `AppEnvironment` builds one client. `ModelAvailabilityService` uses `listAll`
/// to find the models a key can use, and to validate a new key. Settings checks a typed custom ID with
/// `getModel`. These are short calls made while the app is in front, so this client uses
/// async/await on a normal session. Generation never does: it uses the background transport (D§4.5).
///
/// Concurrency: the struct holds only a `URLSession`, which is thread-safe, and immutable settings, so
/// it is `Sendable` and several calls can run at the same time. Each `await` is a suspension point; the
/// client keeps no state across one. Cancellation of the calling task cancels the network call.
struct ModelsClient: Sendable {
  let session: URLSession
  var endpoint = GeminiEndpoint()
  /// Tests tag requests for their mock. Swift note: `inout` lets the closure change the caller's
  /// request in place, and `@Sendable` lets the closure run on any thread.
  var requestDecorator: (@Sendable (inout URLRequest) -> Void)? = nil
  /// A stop for a server that always returns a next-page token, so `listAll` cannot loop forever.
  static let maxPages = 20

  /// An ephemeral session stores no cookies, cache or credentials on disk. `protocolClasses` lets DEBUG
  /// mock mode answer the calls in code (`DebugHooks`).
  static func makeSession(protocolClasses: [AnyClass] = []) -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 20
    c.timeoutIntervalForResource = 20
    c.urlCache = nil
    if !protocolClasses.isEmpty { c.protocolClasses = protocolClasses }
    return URLSession(configuration: c)
  }

  private struct Page: Decodable {
    let models: [ModelInfo]?
    let nextPageToken: String?
  }

  /// Every page, following `nextPageToken`, up to `maxPages`. Also returns the page count, for the
  /// activity log. An empty token means the last page, as does a missing one.
  func listAll(apiKey: String) async throws -> (models: [ModelInfo], pages: Int) {
    var models: [ModelInfo] = []
    var token: String?
    var pages = 0
    repeat {
      let data = try await fetch(endpoint.listModels(pageToken: token, apiKey: apiKey))
      guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw ModelsClientError.malformed }  // Reported as malformed.
      models += page.models ?? []
      token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
      pages += 1
    } while token != nil && pages < Self.maxPages
    return (models, pages)
  }

  func getModel(id: String, apiKey: String) async throws -> ModelInfo {
    let data = try await fetch(endpoint.getModel(id: id, apiKey: apiKey))
    guard let model = try? JSONDecoder().decode(ModelInfo.self, from: data) else { throw ModelsClientError.malformed }  // Reported as malformed.
    return model
  }

  /// True when the list has the default model with `generateContent` support. When it is false, the
  /// app keeps Flash selectable but shows a warning, because the listing can lag (D§2.5).
  static func flashListed(_ models: [ModelInfo]) -> Bool {
    models.contains { $0.id == ModelCatalog.defaultModelID && $0.supportsGenerateContent }
  }

  /// Sends one request and maps every failure to a `ModelsClientError`. Any other error, for example
  /// a `CancellationError`, passes through unchanged.
  private func fetch(_ original: URLRequest) async throws -> Data {
    var request = original
    requestDecorator?(&request)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      // A cancelled call also arrives here, as `URLError.cancelled`.
      throw ModelsClientError.unreachable(Format.urlError(error.code))
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if (200..<300).contains(status) { return data }
    // The API's message when the body is a Google RPC error, else the first 2 KB of the body as text.
    let body = GeminiErrorBody.decode(data)
    let message = body?.message ?? Redactor.utf8Prefix(String(decoding: data.prefix(4096), as: UTF8.self), maxBytes: 2048)
    // A 400 means a bad key only with the `API_KEY_INVALID` reason; any other 400 is a plain HTTP
    // error. A 5xx is a server problem, so it is reported like a network failure.
    switch status {
    case 400 where body?.reason == "API_KEY_INVALID", 401, 403:
      throw ModelsClientError.keyRejected(status: status, apiStatus: body?.status, reason: body?.reason, message: message)
    case 404:
      throw ModelsClientError.notFound(message)
    case 500...599:
      throw ModelsClientError.unreachable("HTTP \(status)")
    default:
      throw ModelsClientError.http(status: status, message: message)
    }
  }
}
