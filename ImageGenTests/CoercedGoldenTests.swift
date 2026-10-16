import Foundation
import Testing

@testable import ImageGen

/// M1 integration: the resolver's coercion feeds the writer end to end.
@Suite(.tags(.io))
struct CoercedGoldenTests {
  @Test func proOverride1x8_512ProducesCoercedGolden() async throws {
    let settings = GenerationSettingsResolver.resolve(
      ChatOverrides(modelID: "gemini-3-pro-image", aspectRatio: .r1x8, imageSize: .s512),
      GenerationDefaults(includeTextModality: true))
    #expect(settings.aspectRatio == .r16x9)
    #expect(settings.imageSize == .s1K)
    #expect(settings.coercions.map(\.field) == [.aspectRatio, .imageSize])

    let root = TestFileRoot()
    let data = try await RequestFixtures.write(
      RequestBodySpec(images: [], promptText: RequestFixtures.lighthouse, settings: settings), root: root)
    let body = try RequestFixtures.json(data)
    let golden = try RequestFixtures.golden("pro_16x9_1k")
    #expect(RequestFixtures.same(body, golden), "\(RequestFixtures.pretty(body))")

    let url = GeminiEndpoint().generateContentRequest(modelID: settings.modelID, apiKey: "k", bodySize: data.count).url
    #expect(url?.path == "/v1beta/models/gemini-3-pro-image:generateContent")
  }
}
