import Foundation

/// What one attempt ended with, as `GenerationService` gives it to `decide`.
enum AttemptResult: Sendable {
  /// The server answered. `error` is the decoded JSON error body, for a non-2xx status.
  case http(status: Int, headers: [String: String], bodyBytes: Int, error: GeminiErrorBody?)
  /// `elapsed` is measured from when the attempt's task began.
  case transport(URLError.Code, elapsed: Duration)
  /// Never retried. `GenerationService` ends a cancelled attempt before it asks the policy.
  case cancelled
}

enum RetryDecision: Sendable, Equatable {
  /// Start the next attempt as a delayed task, after this delay.
  case retry(after: Duration)
  /// Rebuild the body without CIVIC_INTEGRITY and send it again (outside the auto-retry budget).
  case rebuildWithoutCivicAndRetry
  /// No more automatic attempts: save the outcome of this one.
  case finish
}

/// Decides what happens after an attempt (D§6, Retry policy). Pure; the counters come from the
/// persisted request, never from memory.
///
/// `GenerationService` holds one in its `Dependencies` and calls `decide` for each completion, inside
/// the request's turn. A pure value type has no shared state, so any thread can call it. Because the
/// counters come from the record, the budget holds across relaunches.
struct RetryPolicy: Sendable {
  var maxAutoRetries = 2
  var base: Duration = .seconds(2)
  var cap: Duration = .seconds(60)
  /// Equals `timeoutIntervalForResource` (D§4.6).
  var resourceTimeout: Duration = .seconds(1800)
  /// 0..<1, injectable for tests.
  var jitter: @Sendable () -> Double

  init(
    maxAutoRetries: Int = 2, base: Duration = .seconds(2), cap: Duration = .seconds(60),
    resourceTimeout: Duration = .seconds(1800),
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
  ) {
    self.maxAutoRetries = maxAutoRetries
    self.base = base
    self.cap = cap
    self.resourceTimeout = resourceTimeout
    self.jitter = jitter
  }

  /// Request timeout, rate limit, and server errors that may pass on a later attempt.
  static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]
  static let retryableURLErrors: Set<URLError.Code> = [
    .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
  ]

  func decide(
    _ r: AttemptResult, autoRetriesUsed: Int, civicWasSent: Bool, civicFallbackUsed: Bool
  ) -> RetryDecision {
    switch r {
    case .cancelled:
      return .finish

    case .transport(let code, let elapsed):
      // A timeout at or beyond the resource timeout is final; below it, it's the idle timeout.
      let retryable =
        (code == .timedOut && elapsed < resourceTimeout) || Self.retryableURLErrors.contains(code)
      return retryable ? retry(autoRetriesUsed: autoRetriesUsed, hint: nil) : .finish

    case .http(let status, let headers, let bodyBytes, let error):
      if status == 400, let error, error.mentionsCivicIntegrity,
        error.status == nil || error.status == "INVALID_ARGUMENT"
      {
        // Outside the budget, at most once per request.
        return civicWasSent && !civicFallbackUsed ? .rebuildWithoutCivicAndRetry : .finish
      }
      if (200..<300).contains(status) {
        // A 2xx with a body is final, refusals included; an empty body is #33.
        return bodyBytes == 0 ? retry(autoRetriesUsed: autoRetriesUsed, hint: nil) : .finish
      }
      guard Self.retryableStatuses.contains(status) else { return .finish }
      let hint = error?.retryDelay ?? Self.retryAfter(headers)
      return retry(autoRetriesUsed: autoRetriesUsed, hint: hint)
    }
  }

  /// Retries while the budget lasts. The server's hint wins; otherwise the delay is exponential
  /// backoff (2 s, 4 s, …) plus up to 1 s of jitter. Both are capped at `cap`.
  private func retry(autoRetriesUsed: Int, hint: Duration?) -> RetryDecision {
    guard autoRetriesUsed < maxAutoRetries else { return .finish }
    if let hint { return .retry(after: min(hint, cap)) }
    let backoff = base * (1 << max(0, autoRetriesUsed)) + .seconds(jitter())
    return .retry(after: min(backoff, cap))
  }

  /// Whether a transport error can be retried at all (a timeout only below the resource timeout).
  /// `GenerationService` uses it only for the wording of the log step after a `finish`.
  static func isRetryable(_ code: URLError.Code) -> Bool {
    code == .timedOut || retryableURLErrors.contains(code)
  }

  /// `Retry-After` in delta-seconds, matched case-insensitively.
  static func retryAfter(_ headers: [String: String]) -> Duration? {
    guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
      let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
    else { return nil }
    return .seconds(seconds)
  }
}
