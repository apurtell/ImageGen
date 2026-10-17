import Foundation

/// Builds the Gemini REST requests (D§2.4, D§4.5): `generateContent`, `models.list` and `models.get`.
/// The key always travels in the `x-goog-api-key` header, never in the URL, so it never appears in a
/// URL that the system or the activity log could record (D§2.6).
///
/// This is the protocol layer. It only builds `URLRequest` values; it sends nothing. The pipeline
/// (`RequestPreparer`, `URLSessionTransport`) sends generation requests, and `ModelsClient` sends the
/// models calls. Pure: it has no state that changes, so it is `Sendable` and any task can use it at the
/// same time as any other.
struct GeminiEndpoint: Sendable {
  static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
  static let apiKeyHeader = "x-goog-api-key"

  /// The production base URL by default. An instance can use another base URL; the app never does.
  var baseURL: URL = Self.baseURL

  /// `POST …/models/{modelID}:generateContent`, for a body of `bodySize` bytes.
  ///
  /// The request has no body. `URLSessionTransport` uploads the body file that `RequestBodyWriter`
  /// wrote, so `bodySize` must be that file's exact size.
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
    // `URLComponents` percent-encodes the page token, so a token from the server cannot change the URL.
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

  /// `path` is already percent-encoded. Joining strings keeps the path exactly as given, including the
  /// `:` in `:generateContent`. The trailing-slash check prevents a `//` in the path.
  private func url(_ path: String) -> URL {
    let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
    return URL(string: "\(base)/\(path)")!
  }

  /// RFC 3986 unreserved characters only, so `/`, `:`, `?` and spaces in an ID can't change the path.
  /// This matters for custom model IDs, which the user types (D§2.5).
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// One path segment for a model ID. The `?? id` fallback is only reached if encoding fails, which
  /// does not happen for valid Unicode text.
  static func pathSegment(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: unreserved) ?? id
  }
}
