import Foundation

enum AttemptResult: Sendable {
  case http(status: Int, headers: [String: String], bodyBytes: Int, error: GeminiErrorBody?)
  /// `elapsed` is measured from when the attempt's task began.
  case transport(URLError.Code, elapsed: Duration)
  case cancelled
}

enum RetryDecision: Sendable, Equatable {
  case retry(after: Duration)
  case rebuildWithoutCivicAndRetry
  case finish
}

/// Decides what happens after an attempt (D§6, Retry policy). Pure; the counters come from the
/// persisted request, never from memory.
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

  private func retry(autoRetriesUsed: Int, hint: Duration?) -> RetryDecision {
    guard autoRetriesUsed < maxAutoRetries else { return .finish }
    if let hint { return .retry(after: min(hint, cap)) }
    let backoff = base * (1 << max(0, autoRetriesUsed)) + .seconds(jitter())
    return .retry(after: min(backoff, cap))
  }

  /// `Retry-After` in delta-seconds, matched case-insensitively.
  static func retryAfter(_ headers: [String: String]) -> Duration? {
    guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
      let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
    else { return nil }
    return .seconds(seconds)
  }
}
