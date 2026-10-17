import Foundation

/// Represents metadata for an upstream Gemini model entity returned by discovery endpoints.
struct ModelInfo: Sendable, Equatable, Decodable {
  /// Upstream resource name (`models/<id>`).
  let name: String
  let displayName: String?
  let supportedGenerationMethods: [String]?

  /// Canonical model identifier stripped of the `models/` namespace prefix.
  var id: String { name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name }
  var supportsGenerateContent: Bool { supportedGenerationMethods?.contains("generateContent") == true }
}

/// Error categories encountered during model discovery and key validation operations.
enum ModelsClientError: Error, Equatable {
  /// Authentication failure indicated by 400 `API_KEY_INVALID`, 401, or 403.
  case keyRejected(status: Int, apiStatus: String?, reason: String?, message: String)
  /// Network connectivity failure or 5xx server error.
  case unreachable(String)
  case notFound(String)
  case http(status: Int, message: String)
  case malformed
}

/// Client coordinating synchronous REST interactions with model catalog endpoints (`models.list` and `models.get`).
/// Operates over an ephemeral `URLSession` with discrete 20-second timeout constraints, distinct from background generation transfers.
struct ModelsClient: Sendable {
  let session: URLSession
  var endpoint = GeminiEndpoint()
  /// Request interception hook used by unit tests to inject diagnostic headers.
  var requestDecorator: (@Sendable (inout URLRequest) -> Void)? = nil
  /// Maximum pagination threshold to protect against infinite server pagination cycles.
  static let maxPages = 20

  /// Constructs an ephemeral `URLSession` configured to bypass disk caching and persistent cookie storage.
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

  /// Traverses paginated model listings exhaustively up to `maxPages`, returning all accumulated model records and page counts.
  func listAll(apiKey: String) async throws -> (models: [ModelInfo], pages: Int) {
    var models: [ModelInfo] = []
    var token: String?
    var pages = 0
    repeat {
      let data = try await fetch(endpoint.listModels(pageToken: token, apiKey: apiKey))
      guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw ModelsClientError.malformed }
      models += page.models ?? []
      token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
      pages += 1
    } while token != nil && pages < Self.maxPages
    return (models, pages)
  }

  func getModel(id: String, apiKey: String) async throws -> ModelInfo {
    let data = try await fetch(endpoint.getModel(id: id, apiKey: apiKey))
    guard let model = try? JSONDecoder().decode(ModelInfo.self, from: data) else { throw ModelsClientError.malformed }
    return model
  }

  /// Determines whether the discovered model list contains the default Flash model supporting content generation.
  static func flashListed(_ models: [ModelInfo]) -> Bool {
    models.contains { $0.id == ModelCatalog.defaultModelID && $0.supportsGenerateContent }
  }

  /// Dispatches an HTTP request, mapping errors to `ModelsClientError` classifications.
  private func fetch(_ original: URLRequest) async throws -> Data {
    var request = original
    requestDecorator?(&request)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw ModelsClientError.unreachable(Format.urlError(error.code))
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if (200..<300).contains(status) { return data }
    let body = GeminiErrorBody.decode(data)
    let message = body?.message ?? Redactor.utf8Prefix(String(decoding: data.prefix(4096), as: UTF8.self), maxBytes: 2048)
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
