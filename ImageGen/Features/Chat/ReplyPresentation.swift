import Foundation

/// What a request record looks like in the transcript (D§3.4): the single source for card glyphs,
/// titles, message lines and buttons. Pure, so `ReplyPresentationTests` can check every row.
///
/// The views (`ModelReplyView`, `PendingReplyCard`) copy a request record's fields into `Input`,
/// call `make`, and draw the result. The logic has no SwiftUI and no records in it, so it has no
/// threading concerns: it is a function from values to a value. Each case is an enum case with
/// associated values: a pending reply carries its label, a card carries its contents.
enum ReplyPresentation: Equatable {
  /// A request in progress: the pending card, with the line under the timer, or nil for none.
  case pending(label: String?)
  case card(Card)
  /// A success renders the reply's parts; nothing to present here.
  case success

  enum Button: String, Equatable, CaseIterable {
    case retry = "Retry"
    case edit = "Edit"
    case newChat = "New Chat"
    case settings = "Settings"
    case details = "Details"
    case openModels = "Open Models"
  }

  struct Card: Equatable {
    var symbol: String
    var title: String
    var message: String?
    var buttons: [Button]
  }

  /// The request fields that decide the presentation, as plain values. `now` is a field (not a
  /// clock read) so that the countdown is testable and `PendingReplyCard` can pass its timeline date.
  struct Input: Equatable {
    var state: RequestState
    var httpStatus: Int?
    var errorStatus: String?
    var errorMessage: String?
    var details: String?
    var refusalReason: String?
    var finishReason: String?
    var modelID: String
    var aspectRatio: String?
    var imageSize: String?
    var userMessageExists = true
    var autoRetriesUsed = 0
    var maxAutoRetries = 2
    var nextAttemptAt: Date?
    var nextAttemptCreatedInBackground = false
    var isNetworkUnavailable = false
    var now = Date()
  }

  static let pupNote = "This API account is limited by Google; retrying won't help."

  /// The presentation for one request. The `switch` covers every `RequestState`; the compiler
  /// rejects a new state that this function doesn't handle.
  static func make(_ i: Input) -> ReplyPresentation {
    switch i.state {
    case .preparing:
      return .pending(label: "Preparing images…")
    case .inFlight, .parsing, .retryScheduled:
      // `isNetworkUnavailable` already includes "in the foreground" (see `showsWaitingForNetwork`).
      // Parsing needs no network, so it never waits for one.
      if i.isNetworkUnavailable && i.state != .parsing { return .pending(label: "Waiting for network") }
      guard i.state == .retryScheduled else { return .pending(label: nil) }
      let attempt = "attempt \(i.autoRetriesUsed + 1)/\(i.maxAutoRetries + 1)"
      // iOS may defer a retry created in the background, so it gets no countdown (D§6, Retry policy).
      if i.nextAttemptCreatedInBackground || i.nextAttemptAt == nil { return .pending(label: "Retry scheduled (\(attempt))") }
      let seconds = max(0, Int(ceil(i.nextAttemptAt!.timeIntervalSince(i.now))))
      return .pending(label: "Retrying in \(seconds) s (\(attempt))")
    case .succeeded:
      return .success
    case .cancelled:
      return .card(Card(symbol: "stop.circle", title: "Cancelled", message: nil, buttons: [.retry]))
    case .interrupted:
      return .card(
        Card(
          symbol: "bolt.horizontal.circle", title: "Interrupted: the app was closed before the result arrived",
          message: "iOS stopped the request (for example after a force-quit). Retry to send it again.", buttons: [.retry]))
    case .refused:
      let reason = i.refusalReason ?? "UNKNOWN"
      if reason == "PUP_LIMITED_DISABLED" {
        return .card(
          Card(
            symbol: "hand.raised", title: "Request refused: \(reason)", message: pupNote,
            buttons: i.userMessageExists ? [.edit, .newChat] : [.newChat]))
      }
      return .card(
        Card(
          symbol: "hand.raised", title: "Request refused: \(reason)", message: nil,
          buttons: i.userMessageExists ? [.retry, .edit, .newChat] : [.retry, .newChat]))
    case .failed:
      return .card(failed(i))
    }
  }

  /// A failed request's card. Failures the app found itself carry a `LocalErrorStatus` and are
  /// matched first; the rest are HTTP errors from the service, matched by status code.
  private static func failed(_ i: Input) -> Card {
    let message = i.errorMessage.flatMap { $0.isEmpty ? nil : $0 }
    switch i.errorStatus.flatMap(LocalErrorStatus.init(rawValue:)) {
    case .empty:
      return Card(
        symbol: "photo.badge.exclamationmark", title: "No content returned by the model.",
        message: i.finishReason.map { "Finished: \($0)" }, buttons: [.retry, .details])
    case .noAPIKey:
      return Card(symbol: "key", title: "No API key", message: "Add a key in Settings.", buttons: [.settings])
    case .timedOut:
      return Card(
        symbol: "clock.badge.exclamationmark", title: "Timed out", message: message ?? "No response within 5 min.",
        buttons: [.retry, .details])
    case .network:
      return Card(symbol: "wifi.exclamationmark", title: "Network error", message: message, buttons: [.retry, .details])
    case .malformed:
      return Card(
        symbol: "doc.questionmark", title: "Unexpected response", message: "The server didn't return a Gemini response.",
        buttons: [.retry, .details])
    case .tooLarge:
      // The stored message starts "Images too large to send together (N MB)."; the title is that
      // part up to and including ")".
      let title = message.flatMap { m in m.range(of: ")").map { String(m[..<$0.upperBound]) } }
        ?? "Images too large to send together"
      return Card(symbol: "photo.stack", title: title, message: "Remove some or lower the max size in Settings.", buttons: [])
    case .diskFull:
      return Card(
        symbol: "externaldrive.badge.exclamationmark", title: "Not enough storage to save the result",
        message: "Free some space, then retry.", buttons: [.retry])
    case .inputMissing:
      return Card(
        symbol: "photo.badge.exclamationmark", title: "An input image was deleted",
        message: "Edit and Resend with new images.", buttons: [])
    case .emptyParts:
      return Card(symbol: "exclamationmark.triangle", title: "Nothing to send", message: message, buttons: [])
    case nil:
      break
    }
    let code = i.httpStatus ?? 0
    let status = i.errorStatus.map { " \($0)" } ?? ""
    // The service reports a bad key as 400 with this reason in the body, not always as 401 or 403.
    let keyInvalid = i.details?.contains("API_KEY_INVALID") == true
    switch code {
    case 401, 403:
      return Card(symbol: "key", title: "Key rejected (\(code)\(status))", message: message, buttons: [.settings, .details])
    case 400 where keyInvalid:
      return Card(symbol: "key", title: "Key rejected (\(code)\(status))", message: message, buttons: [.settings, .details])
    case 400 where i.errorStatus == "INVALID_ARGUMENT":
      let sent = "Sent: \(i.aspectRatio ?? "default") · \(i.imageSize ?? "default")"
      return Card(
        symbol: "exclamationmark.triangle", title: "Error \(code)\(status)",
        message: [message, sent].compactMap { $0 }.joined(separator: "\n"), buttons: [.details])
    case 402:
      return Card(symbol: "creditcard", title: "Out of credits", message: message, buttons: [.details])
    case 404:
      return Card(
        symbol: "questionmark.circle", title: "Model not found or retired: \(i.modelID)", message: message,
        buttons: [.openModels, .details])
    case 408, 429, 500...599:
      return Card(symbol: "exclamationmark.triangle", title: "Error \(code)\(status)", message: message, buttons: [.retry, .details])
    default:
      return Card(symbol: "exclamationmark.triangle", title: "Error \(code)\(status)", message: message, buttons: [.details])
    }
  }
}

/// The chat list's status for a chat (D§3.3), from its latest request. It is here, next to the
/// reply cards, so that both screens judge "needs attention" from the same states.
enum ChatRowStatus: Equatable {
  case none
  case inFlight
  /// The latest request is `failed` (not an empty reply) or `refused`: it needs attention.
  case needsAttention

  static func make(latestState: RequestState?, errorStatus: String?) -> ChatRowStatus {
    guard let latestState else { return .none }
    if latestState.isLive { return .inFlight }
    if latestState == .refused { return .needsAttention }
    if latestState == .failed && errorStatus != LocalErrorStatus.empty.rawValue { return .needsAttention }
    return .none
  }
}
