import Foundation

/// Builds the Gemini REST requests (D§2.4, D§4.5). The key always travels in the
/// `x-goog-api-key` header, never in the URL. Pure.
struct GeminiEndpoint: Sendable {
  static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
  static let apiKeyHeader = "x-goog-api-key"

  var baseURL: URL = Self.baseURL

  /// `POST …/models/{modelID}:generateContent`, for a body of `bodySize` bytes.
  func generateContentRequest(modelID: String, apiKey: String, bodySize: Int) -> URLRequest {
    var request = URLRequest(url: url("models/\(Self.pathSegment(modelID)):generateContent"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(String(bodySize), forHTTPHeaderField: "Content-Length")
    request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
    return request
  }

  /// `GET …/models?pageSize=1000[&pageToken=…]`.
  func listModels(pageToken: String?, apiKey: String) -> URLRequest {
    var components = URLComponents(url: url("models"), resolvingAgainstBaseURL: false)!
    components.queryItems =
      [URLQueryItem(name: "pageSize", value: "1000")]
      + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
    return getRequest(components.url!, apiKey: apiKey)
  }

  /// `GET …/models/{id}`.
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

  /// `path` is already percent-encoded.
  private func url(_ path: String) -> URL {
    let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
    return URL(string: "\(base)/\(path)")!
  }

  /// RFC 3986 unreserved characters only, so `/`, `:`, `?` and spaces in an ID can't change the path.
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func pathSegment(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
  }
}
