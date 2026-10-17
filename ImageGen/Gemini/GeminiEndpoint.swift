import Foundation

/// Constructs authenticated `URLRequest` specifications for Gemini REST API endpoints,
/// encompassing content generation, model catalog listing, and individual model queries.
/// Transmits API credentials exclusively within the `x-goog-api-key` HTTP header, preventing exposure in request URLs or logging channels.
struct GeminiEndpoint: Sendable {
  static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
  static let apiKeyHeader = "x-goog-api-key"

  /// Base URL endpoint for REST operations. Defaults to the production Gemini v1beta endpoint.
  var baseURL: URL = Self.baseURL

  /// Constructs a `POST` request for model generation. Upload streaming is performed directly from disk via
  /// `URLSessionTransport`, requiring an exact `Content-Length` declaration.
  func generateContentRequest(modelID: String, apiKey: String, bodySize: Int) -> URLRequest {
    var request = URLRequest(url: url("models/\(Self.pathSegment(modelID)):generateContent"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(String(bodySize), forHTTPHeaderField: "Content-Length")
    request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
    return request
  }

  /// Constructs a `GET` request to query the paginated list of models supported by the API.
  func listModels(pageToken: String?, apiKey: String) -> URLRequest {
    var components = URLComponents(url: url("models"), resolvingAgainstBaseURL: false)!
    components.queryItems =
      [URLQueryItem(name: "pageSize", value: "1000")]
      + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
    return getRequest(components.url!, apiKey: apiKey)
  }

  /// Constructs a `GET` request to query metadata for a specific model identifier.
  func getModel(id: String, apiKey: String) -> URLRequest {
    getRequest(url("models/\(Self.pathSegment(id))"), apiKey: apiKey)
  }

  private func getRequest(_ url: URL, apiKey: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
    return request
  }

  /// Appends relative endpoint paths to the configured base URL, preserving custom path delimiters such as `:generateContent`.
  private func url(_ path: String) -> URL {
    let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
    return URL(string: "\(base)/\(path)")!
  }

  /// RFC 3986 unreserved character set ensuring user-supplied model identifiers do not alter URL path structure.
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// Escapes model identifiers into a safe URL path segment.
  static func pathSegment(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
  }
}
