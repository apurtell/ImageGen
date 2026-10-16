import Foundation
import Testing

@testable import ImageGen

@Suite(.tags(.pure))
struct InputSelectorTests {
  // Fixed IDs so failures are readable.
  static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
  let a1 = id(1), a2 = id(2), pin = id(10), u0 = id(20), u1 = id(21), m0 = id(30), m1 = id(31), m2 = id(32)

  func user(_ seq: Int, _ images: [UUID] = [], reply: RequestState? = nil) -> SelectorMessage {
    SelectorMessage(
      sequence: seq, role: .user, replyState: reply,
      images: images.enumerated().map { SelectorImage(id: $1, ordinal: $0) })
  }

  func model(_ seq: Int, _ state: RequestState, _ images: [UUID] = []) -> SelectorMessage {
    SelectorMessage(
      sequence: seq, role: .model, replyState: state,
      images: images.enumerated().map { SelectorImage(id: $1, ordinal: $0) })
  }

  var history: [SelectorMessage] {
    [user(0, [u0]), model(1, .succeeded, [m0])]
  }

  @Test func attachmentsWinAndClearPin() {
    let s = InputSelector.select(
      SelectionInput(attachments: [a1, a2], pinnedImageID: pin, pinnedImageExists: true, history: history))
    #expect(s == Selection(imageIDs: [a1, a2], reason: .attachments, clearPin: true))
    let noPin = InputSelector.select(
      SelectionInput(attachments: [a2, a1], pinnedImageID: nil, pinnedImageExists: false, history: history))
    #expect(noPin == Selection(imageIDs: [a2, a1], reason: .attachments, clearPin: false))
  }

  @Test func pinUsedWhenNoAttachmentsAndCleared() {
    let s = InputSelector.select(
      SelectionInput(attachments: [], pinnedImageID: m0, pinnedImageExists: true,
                     history: history + [model(3, .succeeded, [m1])]))
    #expect(s == Selection(imageIDs: [m0], reason: .pinned, clearPin: true))
  }

  @Test func pinnedUserUploadSelected() {
    let s = InputSelector.select(
      SelectionInput(attachments: [], pinnedImageID: u0, pinnedImageExists: true, history: history))
    #expect(s == Selection(imageIDs: [u0], reason: .pinned, clearPin: true))
  }

  @Test func pinnedAssetMissingFallsThroughToLatest() {
    let s = InputSelector.select(
      SelectionInput(attachments: [], pinnedImageID: pin, pinnedImageExists: false, history: history))
    #expect(s.reason == .latest)
    #expect(s.imageIDs == [m0])
    #expect(s.clearPin)
  }

  @Test(arguments: [RequestState.failed, .refused, .cancelled, .interrupted, .inFlight, .preparing])
  func latestSkipsFailedReplies(state: RequestState) {
    // A model reply that didn't succeed is skipped even if it somehow lists an image.
    let h = [user(0, [u0]), model(1, .succeeded, [m0]), user(2), model(3, state, [m1])]
    let s = InputSelector.select(SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: h))
    #expect(s == Selection(imageIDs: [m0], reason: .latest, clearPin: false))
  }

  @Test func userMessagesEligibleWhateverTheirReply() {
    let h = [model(1, .succeeded, [m0]), user(2, [u0], reply: .failed), model(3, .failed)]
    let s = InputSelector.select(SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: h))
    #expect(s.imageIDs == [u0])
  }

  @Test func latestTakesHighestOrdinal() {
    // Ordinals decide, not array order.
    let message = SelectorMessage(
      sequence: 1, role: .model, replyState: .succeeded,
      images: [SelectorImage(id: m2, ordinal: 2), SelectorImage(id: m0, ordinal: 0), SelectorImage(id: m1, ordinal: 1)])
    let s = InputSelector.select(
      SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: [user(0), message]))
    #expect(s.imageIDs == [m2])
  }

  @Test func userUploadNewerThanModelOutputWins() {
    let h = [user(0), model(1, .succeeded, [m0]), user(2, [u0, u1]), model(3, .succeeded)]
    let s = InputSelector.select(SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: h))
    #expect(s == Selection(imageIDs: [u1], reason: .latest, clearPin: false))
  }

  @Test func latestSkipsTextOnlySucceededReply() {
    let h = [user(0), model(1, .succeeded, [m0]), user(2), model(3, .succeeded)]
    // Shuffled input order: the walk sorts by sequence.
    let s = InputSelector.select(
      SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: h.reversed()))
    #expect(s.imageIDs == [m0])
    #expect(InputSelector.implicitBase(history: h) == m0)
  }

  @Test func noImagesGivesNoImage() {
    let h = [user(0), model(1, .succeeded), user(2), model(3, .refused)]
    let s = InputSelector.select(SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: h))
    #expect(s == Selection(imageIDs: [], reason: .noImage, clearPin: false))
    #expect(InputSelector.implicitBase(history: h) == nil)
    #expect(InputSelector.select(SelectionInput(attachments: [], pinnedImageID: nil, pinnedImageExists: false, history: [])).reason == .noImage)
  }

  struct CanSendRow: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let tray: TrayCounts
    let live: Bool
    let expected: Bool
    var testDescription: String { name }
  }

  @Test(arguments: [
    CanSendRow(name: "text only", text: "hi", tray: TrayCounts(ready: 0, pending: 0, failed: 0), live: false, expected: true),
    CanSendRow(name: "ready attachments only", text: "", tray: TrayCounts(ready: 2, pending: 0, failed: 0), live: false, expected: true),
    CanSendRow(name: "neither", text: "", tray: TrayCounts(ready: 0, pending: 0, failed: 0), live: false, expected: false),
    CanSendRow(name: "live request", text: "hi", tray: TrayCounts(ready: 1, pending: 0, failed: 0), live: true, expected: false),
    CanSendRow(name: "one pending with text", text: "hi", tray: TrayCounts(ready: 1, pending: 1, failed: 0), live: false, expected: false),
    CanSendRow(name: "one failed with text", text: "hi", tray: TrayCounts(ready: 1, pending: 0, failed: 1), live: false, expected: false),
    CanSendRow(name: "only failed, no text", text: "", tray: TrayCounts(ready: 0, pending: 0, failed: 1), live: false, expected: false),
  ])
  func canSendRules(_ row: CanSendRow) {
    #expect(InputSelector.canSend(trimmedText: row.text, tray: row.tray, chatHasLiveRequest: row.live) == row.expected)
  }
}
