import Foundation

/// Intermediate result of a transport attempt provided to the retry evaluation engine.
enum AttemptResult: Sendable {
  /// Upstream HTTP response accompanied by parsed error body when status indicates failure.
  case http(status: Int, headers: [String: String], bodyBytes: Int, error: GeminiErrorBody?)
  /// Network transport error accompanied by elapsed attempt duration.
  case transport(URLError.Code, elapsed: Duration)
  /// Explicit user or system cancellation; excluded from automatic retry evaluation.
  case cancelled
}

enum RetryDecision: Sendable, Equatable {
  /// Schedules a subsequent attempt after the specified backoff duration.
  case retry(after: Duration)
  /// Reconstructs the request body omitting the `HARM_CATEGORY_CIVIC_INTEGRITY` safety category.
  case rebuildWithoutCivicAndRetry
  /// Concludes automatic attempts and transitions request to terminal failure state.
  case finish
}

/// Evaluates network transport outcomes and HTTP status codes against retry policies to determine subsequent dispatch actions.
/// Implemented as a stateless value type where retry quotas are tracked via persisted request record counters across process boundaries.
struct RetryPolicy: Sendable {
  var maxAutoRetries = 2
  var base: Duration = .seconds(2)
  var cap: Duration = .seconds(60)
  /// Total resource timeout threshold matching transport session configuration.
  var resourceTimeout: Duration = .seconds(1800)
  /// Jitter interval generator (0..<1) injected for deterministic testing.
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

  /// Transient HTTP status codes eligible for automatic retry.
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
      // Timeouts exceeding resource timeout threshold are terminal; shorter timeouts represent idle connection drops.
      let retryable =
        (code == .timedOut && elapsed < resourceTimeout) || Self.retryableURLErrors.contains(code)
      return retryable ? retry(autoRetriesUsed: autoRetriesUsed, hint: nil) : .finish

    case .http(let status, let headers, let bodyBytes, let error):
      if status == 400, let error, error.mentionsCivicIntegrity,
        error.status == nil || error.status == "INVALID_ARGUMENT"
      {
        // Rebuild without civic integrity category outside standard retry budget quotas, permitted at most once per request.
        return civicWasSent && !civicFallbackUsed ? .rebuildWithoutCivicAndRetry : .finish
      }
      if (200..<300).contains(status) {
        // Successful status codes with empty payload bodies trigger retry evaluation; populated payloads are terminal.
        return bodyBytes == 0 ? retry(autoRetriesUsed: autoRetriesUsed, hint: nil) : .finish
      }
      guard Self.retryableStatuses.contains(status) else { return .finish }
      let hint = error?.retryDelay ?? Self.retryAfter(headers)
      return retry(autoRetriesUsed: autoRetriesUsed, hint: hint)
    }
  }

  /// Calculates backoff duration honoring upstream hints with exponential backoff and jitter fallback.
  private func retry(autoRetriesUsed: Int, hint: Duration?) -> RetryDecision {
    guard autoRetriesUsed < maxAutoRetries else { return .finish }
    if let hint { return .retry(after: min(hint, cap)) }
    let backoff = base * (1 << max(0, autoRetriesUsed)) + .seconds(jitter())
    return .retry(after: min(backoff, cap))
  }

  /// Evaluates whether a URL error qualifies as retryable.
  static func isRetryable(_ code: URLError.Code) -> Bool {
    code == .timedOut || retryableURLErrors.contains(code)
  }

  /// Parses delta seconds from `Retry-After` response headers case-insensitively.
  static func retryAfter(_ headers: [String: String]) -> Duration? {
    guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
      let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
    else { return nil }
    return .seconds(seconds)
  }
}
