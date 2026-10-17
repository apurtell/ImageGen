import Foundation
import Testing

@testable import ImageGen

/// Validates input selection parity against reference pipe fixtures across all defined test scenarios.
/// Verifies that highest ordinal selection resolves identical inline images to the golden pipeline.
@Suite(.tags(.io))
struct PipeParitySelectionTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let input: SelectionInput
    let reason: SelectionReason
    /// Maps candidate image identifiers to corresponding disk fixture files.
    let files: [UUID: String]
    var testDescription: String { name }
  }

  static let png = UUID(), jpg = UUID(), png2 = UUID(), jpg2 = UUID()

  static func message(_ seq: Int, _ role: Role, _ images: [UUID] = []) -> SelectorMessage {
    SelectorMessage(
      sequence: seq, role: role, replyState: role == .model ? .succeeded : nil,
      images: images.enumerated().map { SelectorImage(id: $1, ordinal: $0) })
  }

  static func input(attachments: [UUID] = [], _ history: [SelectorMessage] = []) -> SelectionInput {
    SelectionInput(attachments: attachments, pinnedImageID: nil, pinnedImageExists: false, history: history)
  }

  static let files: [UUID: String] = [png: "tiny_16x9.png", jpg: "tiny_square.jpg", png2: "tiny_16x9.png", jpg2: "tiny_square.jpg"]

  static let cases: [Case] = [
    Case(name: "p1_text_only", input: input(), reason: .noImage, files: files),
    Case(name: "p2_upload_and_text", input: input(attachments: [png]), reason: .attachments, files: files),
    Case(name: "p3_edit_latest", input: input([message(0, .user), message(1, .model, [png])]), reason: .latest, files: files),
    Case(name: "p4_image_only", input: input(attachments: [jpg]), reason: .attachments, files: files),
    Case(name: "p5_threshold_only_high", input: input(), reason: .noImage, files: files),
    Case(
      name: "p6_latest_is_user_upload", input: input([message(0, .user, [png]), message(1, .model)]),
      reason: .latest, files: files),
    Case(
      name: "p7_latest_of_two_outputs", input: input([message(0, .user), message(1, .model, [png, jpg])]),
      reason: .latest, files: files),
    Case(
      name: "p8_latest_of_two_uploads", input: input([message(0, .user, [png2, jpg2]), message(1, .model)]),
      reason: .latest, files: files),
  ]

  @Test(arguments: cases)
  func selectorPicksPipeImage(_ c: Case) throws {
    let selection = InputSelector.select(c.input)
    #expect(selection.reason == c.reason)

    let pipe = try #require(
      try JSONSerialization.jsonObject(with: FixtureLoader.data("PipeReference/\(c.name).payload.json")) as? [String: Any])
    let parts = try #require(((pipe["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
    let pipeImages = parts.compactMap { $0["inlineData"] as? [String: String] }
    #expect(selection.imageIDs.count == pipeImages.count)
    for (id, sent) in zip(selection.imageIDs, pipeImages) {
      let file = try #require(c.files[id])
      #expect(sent["data"] == (try FixtureLoader.data("Images/\(file)").base64EncodedString()), "\(c.name): \(file)")
      #expect(sent["mimeType"] == MimeTypes.mimeType(forExtension: (file as NSString).pathExtension))
    }
  }
}
