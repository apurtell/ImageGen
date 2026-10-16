import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct ReplyPresentationTests {
  typealias P = ReplyPresentation
  typealias B = ReplyPresentation.Button

  struct Row: Sendable, CustomTestStringConvertible {
    let name: String
    let input: P.Input
    let symbol: String
    let title: String
    let message: String?
    let buttons: [B]
    var testDescription: String { name }
  }

  static func input(_ state: RequestState, http: Int? = nil, status: String? = nil, message: String? = nil, details: String? = nil,
                    refusal: String? = nil, finish: String? = nil, userExists: Bool = true) -> P.Input {
    P.Input(
      state: state, httpStatus: http, errorStatus: status, errorMessage: message, details: details, refusalReason: refusal,
      finishReason: finish, modelID: "gemini-3-pro-image", aspectRatio: "16:9", imageSize: "2K", userMessageExists: userExists)
  }

  static let rows: [Row] = [
    Row(name: "refused IMAGE_SAFETY", input: input(.refused, http: 200, message: "Mock: blocked", refusal: "IMAGE_SAFETY"), symbol: "hand.raised", title: "Request refused: IMAGE_SAFETY", message: nil, buttons: [.retry, .edit, .newChat]),
    Row(name: "refused IMAGE_OTHER", input: input(.refused, refusal: "IMAGE_OTHER"), symbol: "hand.raised", title: "Request refused: IMAGE_OTHER", message: nil, buttons: [.retry, .edit, .newChat]),
    Row(name: "refused PROHIBITED_CONTENT (prompt)", input: input(.refused, refusal: "PROHIBITED_CONTENT"), symbol: "hand.raised", title: "Request refused: PROHIBITED_CONTENT", message: nil, buttons: [.retry, .edit, .newChat]),
    Row(name: "refused unknown reason", input: input(.refused, refusal: "IMAGE_SOMETHING_NEW"), symbol: "hand.raised", title: "Request refused: IMAGE_SOMETHING_NEW", message: nil, buttons: [.retry, .edit, .newChat]),
    Row(name: "refused, user message deleted", input: input(.refused, refusal: "IMAGE_SAFETY", userExists: false), symbol: "hand.raised", title: "Request refused: IMAGE_SAFETY", message: nil, buttons: [.retry, .newChat]),
    Row(name: "PUP_LIMITED_DISABLED", input: input(.refused, refusal: "PUP_LIMITED_DISABLED"), symbol: "hand.raised", title: "Request refused: PUP_LIMITED_DISABLED", message: P.pupNote, buttons: [.edit, .newChat]),
    Row(name: "PUP_LIMITED_DISABLED, user message deleted", input: input(.refused, refusal: "PUP_LIMITED_DISABLED", userExists: false), symbol: "hand.raised", title: "Request refused: PUP_LIMITED_DISABLED", message: P.pupNote, buttons: [.newChat]),
    Row(name: "empty", input: input(.failed, http: 200, status: "EMPTY", finish: "MAX_TOKENS"), symbol: "photo.badge.exclamationmark", title: "No content returned by the model.", message: "Finished: MAX_TOKENS", buttons: [.retry, .details]),
    Row(name: "empty without reason", input: input(.failed, http: 200, status: "EMPTY"), symbol: "photo.badge.exclamationmark", title: "No content returned by the model.", message: nil, buttons: [.retry, .details]),
    Row(name: "no API key", input: input(.failed, status: "NO_API_KEY"), symbol: "key", title: "No API key", message: "Add a key in Settings.", buttons: [.settings]),
    Row(name: "key rejected 403", input: input(.failed, http: 403, status: "PERMISSION_DENIED", message: "denied"), symbol: "key", title: "Key rejected (403 PERMISSION_DENIED)", message: "denied", buttons: [.settings, .details]),
    Row(name: "key rejected 400 API_KEY_INVALID", input: input(.failed, http: 400, status: "INVALID_ARGUMENT", message: "API key not valid.", details: "\"reason\": \"API_KEY_INVALID\""), symbol: "key", title: "Key rejected (400 INVALID_ARGUMENT)", message: "API key not valid.", buttons: [.settings, .details]),
    Row(name: "bad config", input: input(.failed, http: 400, status: "INVALID_ARGUMENT", message: "Unsupported aspect"), symbol: "exclamationmark.triangle", title: "Error 400 INVALID_ARGUMENT", message: "Unsupported aspect\nSent: 16:9 · 2K", buttons: [.details]),
    Row(name: "billing or region", input: input(.failed, http: 400, status: "FAILED_PRECONDITION", message: "Billing"), symbol: "exclamationmark.triangle", title: "Error 400 FAILED_PRECONDITION", message: "Billing", buttons: [.details]),
    Row(name: "out of credits", input: input(.failed, http: 402, status: "FAILED_PRECONDITION", message: "credits"), symbol: "creditcard", title: "Out of credits", message: "credits", buttons: [.details]),
    Row(name: "model not found", input: input(.failed, http: 404, status: "NOT_FOUND", message: "gone"), symbol: "questionmark.circle", title: "Model not found or retired: gemini-3-pro-image", message: "gone", buttons: [.openModels, .details]),
    Row(name: "rate limit after retries", input: input(.failed, http: 429, status: "RESOURCE_EXHAUSTED", message: "quota"), symbol: "exclamationmark.triangle", title: "Error 429 RESOURCE_EXHAUSTED", message: "quota", buttons: [.retry, .details]),
    Row(name: "server error", input: input(.failed, http: 503, status: "UNAVAILABLE", message: "overloaded"), symbol: "exclamationmark.triangle", title: "Error 503 UNAVAILABLE", message: "overloaded", buttons: [.retry, .details]),
    Row(name: "timed out", input: input(.failed, status: "TIMED_OUT", message: "No response within 30 min."), symbol: "clock.badge.exclamationmark", title: "Timed out", message: "No response within 30 min.", buttons: [.retry, .details]),
    Row(name: "network error", input: input(.failed, status: "NETWORK", message: "notConnectedToInternet"), symbol: "wifi.exclamationmark", title: "Network error", message: "notConnectedToInternet", buttons: [.retry, .details]),
    Row(name: "malformed", input: input(.failed, http: 200, status: "MALFORMED"), symbol: "doc.questionmark", title: "Unexpected response", message: "The server didn't return a Gemini response.", buttons: [.retry, .details]),
    Row(name: "too large", input: input(.failed, status: "TOO_LARGE", message: "Images too large to send together (23.4 MB). Remove some or lower the max size in Settings."), symbol: "photo.stack", title: "Images too large to send together (23.4 MB)", message: "Remove some or lower the max size in Settings.", buttons: []),
    Row(name: "disk full", input: input(.failed, status: "DISK_FULL"), symbol: "externaldrive.badge.exclamationmark", title: "Not enough storage to save the result", message: "Free some space, then retry.", buttons: [.retry]),
    Row(name: "cancelled", input: input(.cancelled), symbol: "stop.circle", title: "Cancelled", message: nil, buttons: [.retry]),
    Row(name: "interrupted", input: input(.interrupted), symbol: "bolt.horizontal.circle", title: "Interrupted: the app was closed before the result arrived", message: "iOS stopped the request (for example after a force-quit). Retry to send it again.", buttons: [.retry]),
  ]

  @Test(arguments: rows)
  func cardTable(_ row: Row) {
    guard case .card(let card) = P.make(row.input) else {
      Issue.record("\(row.name): not a card")
      return
    }
    #expect(card.symbol == row.symbol)
    #expect(card.title == row.title)
    #expect(card.message == row.message)
    #expect(card.buttons == row.buttons)
  }

  @Test func pendingStates() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var i = Self.input(.preparing)
    i.now = now
    #expect(P.make(i) == .pending(label: "Preparing images…"))
    i.state = .inFlight
    #expect(P.make(i) == .pending(label: nil))
    i.isNetworkUnavailable = true
    #expect(P.make(i) == .pending(label: "Waiting for network"))
    i.isNetworkUnavailable = false
    i.state = .retryScheduled
    i.autoRetriesUsed = 1
    i.nextAttemptAt = now.addingTimeInterval(1.2)
    #expect(P.make(i) == .pending(label: "Retrying in 2 s (attempt 2/3)"))
    i.nextAttemptCreatedInBackground = true
    #expect(P.make(i) == .pending(label: "Retry scheduled (attempt 2/3)"))
    i.state = .parsing
    #expect(P.make(i) == .pending(label: nil))
    #expect(P.make(Self.input(.succeeded)) == .success)
  }

  @Test func refusalNotificationBody() {
    #expect(NotificationPoster.body(state: .refused, imageCount: 0, text: nil, refusalReason: "IMAGE_SAFETY", failure: nil) == "Request refused: IMAGE_SAFETY")
  }

  @Test(arguments: [
    (RequestState.failed, String?.none, ChatRowStatus.needsAttention), (.refused, nil, .needsAttention), (.succeeded, nil, .none),
    (.failed, "EMPTY", .none), (.cancelled, nil, .none), (.interrupted, nil, .none), (.inFlight, nil, .inFlight),
    (.preparing, nil, .inFlight), (.retryScheduled, nil, .inFlight), (.parsing, nil, .inFlight),
  ])
  func chatRowStatus(state: RequestState, errorStatus: String?, expected: ChatRowStatus) {
    #expect(ChatRowStatus.make(latestState: state, errorStatus: errorStatus) == expected)
  }

  @Test func noRequestNoStatus() {
    #expect(ChatRowStatus.make(latestState: nil, errorStatus: nil) == .none)
  }
}

@Suite(.tags(.pure))
struct AutoTitleTests {
  @Test(arguments: [
    ("A lighthouse on a rocky point at dusk with a purple sky", "A lighthouse on a rocky point at dusk with a"),
    ("short", "short"),
    (String(repeating: "word ", count: 20), "word word word word word word word word word"),
    ("Supercalifragilisticexpialidocious-and-even-longer-words-here", "Supercalifragilisticexpialidocious-and-even-long"),
  ])
  func cutAt48OnWordBoundary(prompt: String, title: String) {
    let t = DataStore.automaticTitle(prompt)
    #expect(t == title)
    #expect(t.count <= 48)
  }
}
