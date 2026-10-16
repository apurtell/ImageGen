import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct EndpointTests {
  let endpoint = GeminiEndpoint()
  let key = "AIzaSyTESTKEY-0123456789abcdefghijklmnopq"

  @Test func urlHasNoKeyQuery() {
    let requests = [
      endpoint.generateContentRequest(modelID: "gemini-3.1-flash-image", apiKey: key, bodySize: 10),
      endpoint.listModels(pageToken: "t", apiKey: key),
      endpoint.getModel(id: "gemini-x-test", apiKey: key),
    ]
    for r in requests {
      let url = r.url!.absoluteString
      #expect(!url.contains("key="))
      #expect(!url.contains(key))
    }
    #expect(
      requests[0].url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent")
    #expect(requests[0].url?.query == nil)
  }

  @Test func headerCarriesKey() {
    let r = endpoint.generateContentRequest(modelID: "gemini-3.1-flash-image", apiKey: key, bodySize: 10)
    #expect(r.value(forHTTPHeaderField: "x-goog-api-key") == key)
    #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(endpoint.listModels(pageToken: nil, apiKey: key).value(forHTTPHeaderField: "x-goog-api-key") == key)
    #expect(endpoint.getModel(id: "m", apiKey: key).value(forHTTPHeaderField: "x-goog-api-key") == key)
  }

  @Test func methodIsPost() {
    #expect(endpoint.generateContentRequest(modelID: "m", apiKey: key, bodySize: 1).httpMethod == "POST")
    #expect(endpoint.listModels(pageToken: nil, apiKey: key).httpMethod == "GET")
    #expect(endpoint.getModel(id: "m", apiKey: key).httpMethod == "GET")
  }

  @Test func contentLengthMatchesBodySize() throws {
    let spec = RequestBodySpec(images: [], promptText: "hello", settings: RequestFixtures.settings())
    let size = try RequestBodyWriter.predictedSize(spec)
    let r = endpoint.generateContentRequest(modelID: "m", apiKey: key, bodySize: size)
    #expect(r.value(forHTTPHeaderField: "Content-Length") == String(size))
  }

  @Test(arguments: [
    ("gemini-x-test", "gemini-x-test"),
    ("gemini-3.1-flash-image", "gemini-3.1-flash-image"),
    ("my model/v2:beta?x#y", "my%20model%2Fv2%3Abeta%3Fx%23y"),
  ])
  func modelIDPercentEncoded(id: String, encoded: String) {
    let r = endpoint.generateContentRequest(modelID: id, apiKey: key, bodySize: 1)
    #expect(
      r.url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent")
    #expect(
      endpoint.getModel(id: id, apiKey: key).url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/\(encoded)")
  }

  @Test func listModelsUsesPageSize1000AndToken() throws {
    let first = try #require(endpoint.listModels(pageToken: nil, apiKey: key).url)
    #expect(first.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
    let next = try #require(endpoint.listModels(pageToken: "page-2 token", apiKey: key).url)
    let items = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items == [URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "pageToken", value: "page-2 token")])
  }
}
