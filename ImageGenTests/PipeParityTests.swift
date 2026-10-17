import Foundation
import Testing

@testable import ImageGen

/// Validates serialized request body and endpoint URL parity against reference pipe fixtures,
/// accounting for intentional design deviations including `generationConfig.imageConfig` and header-based authentication.
@Suite(.tags(.io))
struct PipeParityTests {
  typealias F = RequestFixtures

  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    /// Synthetic input specifications configured directly for fixture comparison.
    let images: [String]
    let prompt: String
    var threshold: SafetyThreshold = .blockNone
    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(name: "p1_text_only", images: [], prompt: "a lighthouse at dusk"),
    Case(name: "p2_upload_and_text", images: ["tiny_16x9.png"], prompt: "make it night"),
    Case(name: "p3_edit_latest", images: ["tiny_16x9.png"], prompt: "add a full moon"),
    Case(name: "p4_image_only", images: ["tiny_square.jpg"], prompt: ""),
    Case(name: "p5_threshold_only_high", images: [], prompt: "a lighthouse at dusk", threshold: .blockOnlyHigh),
    Case(name: "p6_latest_is_user_upload", images: ["tiny_16x9.png"], prompt: "now make it blue"),
    Case(name: "p7_latest_of_two_outputs", images: ["tiny_square.jpg"], prompt: "use the second one"),
    Case(name: "p8_latest_of_two_uploads", images: ["tiny_square.jpg"], prompt: "edit the last one"),
  ]

  @Test(arguments: cases)
  func bodyAndURLMatchPipe(_ c: Case) async throws {
    let root = TestFileRoot()
    let settings = F.settings(threshold: c.threshold)
    let spec = RequestBodySpec(images: try c.images.map(F.image), promptText: c.prompt, settings: settings)
    let data = try await F.write(spec, root: root)

    var app = try #require(try F.json(data) as? [String: Any])
    var config = try #require(app["generationConfig"] as? [String: Any])
    #expect(config["imageConfig"] != nil)
    config.removeValue(forKey: "imageConfig")
    app["generationConfig"] = config

    let pipe = try F.json(try FixtureLoader.data("PipeReference/\(c.name).payload.json"))
    #expect(F.same(app, pipe), "\(F.pretty(app))\n— vs pipe —\n\(F.pretty(pipe))")

    let pipeURL = try FixtureLoader.string("PipeReference/\(c.name).url.txt")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(pipeURL.hasSuffix("?key=<KEY>"))
    let request = GeminiEndpoint().generateContentRequest(
      modelID: settings.modelID, apiKey: "k", bodySize: data.count)
    #expect(request.url?.absoluteString == String(pipeURL.dropLast("?key=<KEY>".count)))
  }

  @Test func allEightCasesHaveFixtures() throws {
    let names = Set(try FixtureLoader.names(in: "PipeReference"))
    for c in Self.cases {
      #expect(names.contains("\(c.name).payload.json"))
      #expect(names.contains("\(c.name).url.txt"))
    }
    #expect(Self.cases.count == 8)
  }
}
