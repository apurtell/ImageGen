import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct RetryPolicyTests {
  let policy = RetryPolicy(jitter: { 0 })

  func decide(
    _ r: AttemptResult, used: Int = 0, civicSent: Bool = true, civicUsed: Bool = false, policy p: RetryPolicy? = nil
  ) -> RetryDecision {
    (p ?? policy).decide(r, autoRetriesUsed: used, civicWasSent: civicSent, civicFallbackUsed: civicUsed)
  }

  static let civicError = GeminiErrorBody(
    code: 400, message: "Invalid value at 'safety_settings[4].category', \"HARM_CATEGORY_CIVIC_INTEGRITY\"",
    status: "INVALID_ARGUMENT")
  static let plain400 = GeminiErrorBody(code: 400, message: "Unsupported aspect ratio", status: "INVALID_ARGUMENT")

  struct StatusRow: Sendable, CustomTestStringConvertible {
    let name: String
    let status: Int
    let bodyBytes: Int
    let error: GeminiErrorBody?
    let expected: RetryDecision
    var testDescription: String { name }
  }

  @Test(arguments: [
    StatusRow(name: "200 with a body", status: 200, bodyBytes: 512, error: nil, expected: .finish),
    StatusRow(name: "200 empty", status: 200, bodyBytes: 0, error: nil, expected: .retry(after: .seconds(2))),
    StatusRow(name: "400", status: 400, bodyBytes: 80, error: plain400, expected: .finish),
    StatusRow(name: "400 civic", status: 400, bodyBytes: 80, error: civicError, expected: .rebuildWithoutCivicAndRetry),
    StatusRow(name: "401", status: 401, bodyBytes: 80, error: nil, expected: .finish),
    StatusRow(name: "402", status: 402, bodyBytes: 80, error: nil, expected: .finish),
    StatusRow(name: "403", status: 403, bodyBytes: 80, error: nil, expected: .finish),
    StatusRow(name: "404", status: 404, bodyBytes: 80, error: nil, expected: .finish),
    StatusRow(name: "408", status: 408, bodyBytes: 0, error: nil, expected: .retry(after: .seconds(2))),
    StatusRow(name: "429", status: 429, bodyBytes: 80, error: nil, expected: .retry(after: .seconds(2))),
    StatusRow(name: "500", status: 500, bodyBytes: 80, error: nil, expected: .retry(after: .seconds(2))),
    StatusRow(name: "502", status: 502, bodyBytes: 80, error: nil, expected: .retry(after: .seconds(2))),
    StatusRow(name: "503", status: 503, bodyBytes: 80, error: nil, expected: .retry(after: .seconds(2))),
    StatusRow(name: "504", status: 504, bodyBytes: 80, error: nil, expected: .retry(after: .seconds(2))),
  ])
  func statusMatrix(_ row: StatusRow) {
    #expect(decide(.http(status: row.status, headers: [:], bodyBytes: row.bodyBytes, error: row.error)) == row.expected)
  }

  @Test(arguments: [
    (URLError.Code.timedOut, Duration.seconds(299), true),
    (.timedOut, .seconds(1800), false),
    (.timedOut, .seconds(2400), false),
    (.networkConnectionLost, .seconds(5), true),
    (.notConnectedToInternet, .seconds(5), true),
    (.cannotConnectToHost, .seconds(5), true),
    (.badURL, .seconds(0), false),
    (.secureConnectionFailed, .seconds(1), false),
  ])
  func urlErrorMatrix(code: URLError.Code, elapsed: Duration, retries: Bool) {
    #expect(decide(.transport(code, elapsed: elapsed)) == (retries ? .retry(after: .seconds(2)) : .finish))
  }

  @Test func sharedBudgetAcrossCauses() {
    #expect(decide(.http(status: 429, headers: [:], bodyBytes: 10, error: nil), used: 0) == .retry(after: .seconds(2)))
    #expect(decide(.transport(.timedOut, elapsed: .seconds(300)), used: 1) == .retry(after: .seconds(4)))
    #expect(decide(.http(status: 200, headers: [:], bodyBytes: 0, error: nil), used: 2) == .finish)
  }

  @Test func cancelledNeverRetries() {
    #expect(decide(.cancelled, used: 0) == .finish)
  }

  @Test func budgetExhaustedFinishes() {
    #expect(decide(.http(status: 503, headers: [:], bodyBytes: 10, error: nil), used: 2) == .finish)
    #expect(decide(.transport(.networkConnectionLost, elapsed: .seconds(1)), used: 3) == .finish)
    let generous = RetryPolicy(maxAutoRetries: 3, jitter: { 0 })
    #expect(decide(.http(status: 503, headers: [:], bodyBytes: 10, error: nil), used: 2, policy: generous) == .retry(after: .seconds(8)))
  }

  @Test func exponentialWithSeededJitter() {
    let seeded = RetryPolicy(jitter: { 0.25 })
    let r = AttemptResult.http(status: 500, headers: [:], bodyBytes: 10, error: nil)
    #expect(decide(r, used: 0, policy: seeded) == .retry(after: .milliseconds(2250)))
    #expect(decide(r, used: 1, policy: seeded) == .retry(after: .milliseconds(4250)))
  }

  @Test func retryInfoHonoredAndCapped() throws {
    let fixture = try #require(GeminiErrorBody.decode(FixtureLoader.data("Errors/err_429_retryinfo.json")))
    #expect(decide(.http(status: 429, headers: [:], bodyBytes: 900, error: fixture)) == .retry(after: .seconds(30)))
    let long = GeminiErrorBody(
      code: 429, message: "quota", status: "RESOURCE_EXHAUSTED",
      details: [.object(["@type": .string("type.googleapis.com/google.rpc.RetryInfo"), "retryDelay": .string("90s")])])
    #expect(decide(.http(status: 429, headers: [:], bodyBytes: 100, error: long)) == .retry(after: .seconds(60)))
    // The hint replaces the backoff and its jitter.
    let jittery = RetryPolicy(jitter: { 0.9 })
    #expect(decide(.http(status: 429, headers: [:], bodyBytes: 900, error: fixture), used: 1, policy: jittery) == .retry(after: .seconds(30)))
  }

  @Test func retryAfterHeaderHonored() {
    #expect(decide(.http(status: 503, headers: ["Retry-After": "7"], bodyBytes: 10, error: nil)) == .retry(after: .seconds(7)))
    #expect(decide(.http(status: 503, headers: ["retry-after": "120"], bodyBytes: 10, error: nil)) == .retry(after: .seconds(60)))
    #expect(decide(.http(status: 503, headers: ["Retry-After": "soon"], bodyBytes: 10, error: nil)) == .retry(after: .seconds(2)))
  }

  @Test func civicFallbackOnlyOnce() {
    let r = AttemptResult.http(status: 400, headers: [:], bodyBytes: 80, error: Self.civicError)
    #expect(decide(r, civicSent: true, civicUsed: false) == .rebuildWithoutCivicAndRetry)
    #expect(decide(r, civicSent: true, civicUsed: true) == .finish)
    #expect(decide(r, civicSent: false, civicUsed: false) == .finish)
    // Outside the budget.
    #expect(decide(r, used: 2, civicSent: true, civicUsed: false) == .rebuildWithoutCivicAndRetry)
  }

  @Test(arguments: [
    "Responses/resp_image_safety.json", "Responses/resp_prompt_refused.json", "Responses/resp_refused_with_text.json",
  ])
  func refusalNeverRetried(file: String) throws {
    let body = try FixtureLoader.data(file)
    let r = AttemptResult.http(status: 200, headers: [:], bodyBytes: body.count, error: GeminiErrorBody.decode(body))
    #expect(decide(r, used: 0, civicSent: true, civicUsed: false) == .finish)
  }
}
