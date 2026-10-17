import Foundation
import Synchronization
import Testing

@testable import ImageGen

@Suite
struct RequestBodyWriterTests {
  typealias F = RequestFixtures

  struct GoldenCase: Sendable, CustomTestStringConvertible {
    let golden: String
    let images: [String]
    let prompt: String?
    let settings: EffectiveSettings
    var testDescription: String { golden }
  }

  static let goldenCases: [GoldenCase] = [
    // Sets includeTextModality explicitly to preserve deterministic request payloads.
    GoldenCase(golden: "flash_text_only_16x9_2k", images: [], prompt: F.lighthouse, settings: F.settings(includeText: true)),
    GoldenCase(
      golden: "flash_three_images", images: ["tiny_square.jpg", "tiny_16x9.png", "rotated_exif6.jpg"],
      prompt: "combine these into one scene", settings: F.settings()),
    GoldenCase(golden: "flash_image_only", images: ["tiny_16x9.png"], prompt: "", settings: F.settings()),
    GoldenCase(golden: "flash_512_9x16", images: [], prompt: F.lighthouse, settings: F.settings(aspect: .r9x16, size: .s512)),
    GoldenCase(
      golden: "pro_16x9_1k", images: [], prompt: F.lighthouse,
      settings: F.settings(model: "gemini-3-pro-image", size: .s1K)),
    GoldenCase(
      golden: "flash25_no_image_size", images: [], prompt: F.lighthouse,
      settings: F.settings(model: "gemini-2.5-flash-image", size: nil)),
    GoldenCase(
      golden: "flash_no_civic", images: [], prompt: F.lighthouse,
      settings: F.settings(categories: HarmCategory.allCases.filter { $0 != .civicIntegrity })),
    GoldenCase(
      golden: "flash_image_modality_only", images: [], prompt: F.lighthouse, settings: F.settings(includeText: false)),
    GoldenCase(golden: "flash_escaping", images: [], prompt: escapingPrompt, settings: F.settings()),
    GoldenCase(
      golden: "custom_model_4k", images: [], prompt: F.lighthouse,
      settings: F.settings(model: "gemini-x-test", aspect: .r21x9, size: .s4K)),
  ]

  static let escapingPrompt =
    "She said \"hi\" \\ C:\\path\nsecond line\ttab \u{1F3A8}\u{1F3DD}\u{FE0F} sep\u{2028}end /slash"

  @Test(.tags(.io), arguments: goldenCases)
  func goldenMatches(_ c: GoldenCase) async throws {
    let root = TestFileRoot()
    let spec = RequestBodySpec(images: try c.images.map(F.image), promptText: c.prompt, settings: c.settings)
    let body = try F.json(try await F.write(spec, root: root))
    let golden = try F.golden(c.golden)
    #expect(F.same(body, golden), "\(F.pretty(body))\n— vs golden —\n\(F.pretty(golden))")
  }

  @Test(.tags(.io), arguments: [
    ("flash_threshold_only_high", SafetyThreshold.blockOnlyHigh),
    ("flash_threshold_medium", .blockMediumAndAbove),
    ("flash_threshold_low", .blockLowAndAbove),
  ])
  func thresholdGoldens(golden: String, threshold: SafetyThreshold) async throws {
    let root = TestFileRoot()
    let spec = RequestBodySpec(images: [], promptText: F.lighthouse, settings: F.settings(threshold: threshold))
    let body = try F.json(try await F.write(spec, root: root))
    #expect(F.same(body, try F.golden(golden)))
    let safety = try #require((body as? [String: Any])?["safetySettings"] as? [[String: String]])
    #expect(safety.count == 5)
    #expect(safety.allSatisfy { $0["threshold"] == threshold.rawValue })
  }

  @Test(.tags(.io)) func goldenFileHas16x9And2K() throws {
    let text = try FixtureLoader.string("Requests/flash_text_only_16x9_2k.json")
    #expect(text.contains(#""aspectRatio":"16:9""#))
    #expect(text.contains(#""imageSize":"2K""#))
  }

  @Test(.tags(.io)) func imagesBeforeText() async throws {
    let root = TestFileRoot()
    let spec = RequestBodySpec(
      images: [try F.image("tiny_16x9.png"), try F.image("tiny_square.jpg")], promptText: "go",
      settings: F.settings())
    let body = try #require(try F.json(try await F.write(spec, root: root)) as? [String: Any])
    let parts = try #require(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
    #expect(parts.map { $0.keys.sorted() } == [["inlineData"], ["inlineData"], ["text"]])
    #expect((parts[0]["inlineData"] as? [String: String])?["mimeType"] == "image/png")
    #expect((parts[1]["inlineData"] as? [String: String])?["mimeType"] == "image/jpeg")
  }

  @Test(.tags(.io)) func whitespaceOnlyPromptOmitsTextPart() async throws {
    let root = TestFileRoot()
    let spec = RequestBodySpec(images: [try F.image("tiny_16x9.png")], promptText: " \n\t ", settings: F.settings())
    let body = try F.json(try await F.write(spec, root: root))
    #expect(F.same(body, try F.golden("flash_image_only")))
  }

  @Test(.tags(.io)) func escapingRoundTripsExactly() async throws {
    let root = TestFileRoot()
    let spec = RequestBodySpec(images: [], promptText: Self.escapingPrompt, settings: F.settings())
    let body = try #require(try F.json(try await F.write(spec, root: root)) as? [String: Any])
    let parts = try #require(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
    #expect(parts.first?["text"] as? String == Self.escapingPrompt)
  }

  @Test(.tags(.pure)) func emptyPartsThrows() async throws {
    let root = TestFileRoot()
    for prompt in [nil, "", "  \n "] as [String?] {
      let spec = RequestBodySpec(images: [], promptText: prompt, settings: F.settings())
      #expect(throws: RequestBodyError.emptyParts) { try RequestBodyWriter.predictedSize(spec) }
      await #expect(throws: RequestBodyError.emptyParts) {
        _ = try await RequestBodyWriter.write(spec, to: root.file("body.json"))
      }
    }
  }

  @Test(.tags(.io), arguments: [
    [Int](), [3_000], [3_001, 3_002], [3_000, 3_001, 3_002], [49_152, 49_153], [5_000_000],
  ])
  func predictedSizeEqualsWrittenSize(imageSizes: [Int]) async throws {
    let root = TestFileRoot()
    let images = try imageSizes.enumerated().map { i, n in
      let url = root.file("in-\(i).bin")
      try Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) }).write(to: url)
      return BodyImage(fileURL: url, mimeType: "image/jpeg", byteCount: n)
    }
    let spec = RequestBodySpec(images: images, promptText: "size check", settings: F.settings())
    let predicted = try RequestBodyWriter.predictedSize(spec)
    let url = root.file("body.json")
    let written = try await RequestBodyWriter.write(spec, to: url)
    let onDisk = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    #expect(predicted == written)
    #expect(onDisk == written)
    // Verifies that stream-encoded base64 payloads reconstruct exact source image bytes.
    let body = try #require(try F.json(Data(contentsOf: url)) as? [String: Any])
    let parts = try #require(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
    for (i, image) in images.enumerated() {
      let b64 = try #require((parts[i]["inlineData"] as? [String: String])?["data"])
      #expect(Data(base64Encoded: b64) == (try Data(contentsOf: image.fileURL)))
    }
  }

  @Test(.tags(.io)) func changedImageFileThrows() async throws {
    let root = TestFileRoot()
    let url = root.file("in.bin")
    try Data(count: 100).write(to: url)
    let spec = RequestBodySpec(
      images: [BodyImage(fileURL: url, mimeType: "image/png", byteCount: 99)], promptText: nil, settings: F.settings())
    await #expect(throws: RequestBodyError.imageSizeMismatch(index: 0, expected: 99, actual: 100)) {
      _ = try await RequestBodyWriter.write(spec, to: root.file("body.json"))
    }
  }

  @Test(.tags(.io)) func noFullBodyInMemory() async throws {
    let root = TestFileRoot()
    let input = root.file("big.bin")
    let size = 15 * 1024 * 1024
    FileManager.default.createFile(atPath: input.path, contents: nil)
    let handle = try FileHandle(forWritingTo: input)
    let mb = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    for _ in 0..<15 { try handle.write(contentsOf: mb) }
    try handle.close()

    let spec = RequestBodySpec(
      images: [BodyImage(fileURL: input, mimeType: "image/jpeg", byteCount: size)], promptText: "big",
      settings: F.settings())
    let baseline = Memory.physFootprint()
    let peak = Mutex(baseline)
    let done = Mutex(false)
    let sampler = Task.detached {
      while !done.withLock({ $0 }) {
        let now = Memory.physFootprint()
        peak.withLock { $0 = max($0, now) }
        try? await Task.sleep(for: .milliseconds(2))
      }
    }
    let written = try await RequestBodyWriter.write(spec, to: root.file("body.json"))
    done.withLock { $0 = true }
    await sampler.value
    let growth = Int64(peak.withLock { $0 }) - Int64(baseline)
    #expect(written > 20 * 1024 * 1024)
    #expect(growth < 8 * 1024 * 1024, "phys_footprint grew \(growth / 1024) KB while writing")
  }
}

enum Memory {
  static func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
