import Foundation

/// Represents the user facing presentation model for model replies within the transcript,
/// serving as the single deterministic mapping from generation request state to UI symbols,
/// titles, descriptions, and recovery action buttons.
///
/// Designed as a pure functional transform independent of SwiftUI dependencies or SwiftData
/// actor boundaries, enabling exhaustive unit testing across all permutations of request states,
/// network conditions, local errors, and HTTP response statuses.
enum ReplyPresentation: Equatable {
  /// An active in-flight request displaying progressive status messaging or countdown timers.
  case pending(label: String?)
  case card(Card)
  /// A completed generation requiring no placeholder or status card presentation.
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

  /// Parameter container encapsulating request metadata, network availability, retry state,
  /// and timestamp references required for deterministic presentation evaluation.
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

  /// Evaluates presentation state for an input configuration across all `RequestState` transitions.
  static func make(_ i: Input) -> ReplyPresentation {
    switch i.state {
    case .preparing:
      return .pending(label: "Preparing images…")
    case .inFlight, .parsing, .retryScheduled:
      // Suppress network wait messaging during payload parsing phases that require no active transport.
      if i.isNetworkUnavailable && i.state != .parsing { return .pending(label: "Waiting for network") }
      guard i.state == .retryScheduled else { return .pending(label: nil) }
      let attempt = "attempt \(i.autoRetriesUsed + 1)/\(i.maxAutoRetries + 1)"
      // Background retry attempts are subject to system scheduling discretion, omitting precise countdown timers.
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

  /// Constructs diagnostic card presentation for failed requests, evaluating client side
  /// validation errors before inspecting backend HTTP response codes and error bodies.
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
      // Extract the leading dimension summary clause from composite payload limit diagnostics.
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
    // APIs may return invalid credentials as HTTP 400 with API_KEY_INVALID in payload details.
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

/// Summarized conversational status derived from the latest generation request, shared across
/// chat list rows and transcript views to unify visual indicators for active and degraded sessions.
enum ChatRowStatus: Equatable {
  case none
  case inFlight
  /// Indicates an unresolved refusal or non-empty failure requiring explicit user intervention.
  case needsAttention

  static func make(latestState: RequestState?, errorStatus: String?) -> ChatRowStatus {
    guard let latestState else { return .none }
    if latestState.isLive { return .inFlight }
    if latestState == .refused { return .needsAttention }
    if latestState == .failed && errorStatus != LocalErrorStatus.empty.rawValue { return .needsAttention }
    return .none
  }
}
