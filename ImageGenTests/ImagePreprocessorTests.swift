import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ImageGen

@Suite(.tags(.io))
struct ImagePreprocessorTests {
  func prepare(_ source: URL, edge: Int = 2048, root: TestFileRoot) async throws -> PreparedImage {
    try await ImagePreprocessor.prepare(source: source, maxLongEdge: edge, destinationDir: root.directory("prepared"), id: UUID())
  }

  func write(_ data: Data, _ name: String, root: TestFileRoot) throws -> URL {
    let url = root.file(name)
    try data.write(to: url)
    return url
  }

  /// RGBA of one pixel of an encoded image, decoded in full (test images are small).
  func pixel(_ url: URL, x: Int, y: Int) throws -> [UInt8] {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var out = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(
      CGContext(
        data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return out
  }

  /// A transparent canvas with an opaque red square in the middle.
  static func transparentWithSquare(width: Int = 64, height: Int = 48) -> CGImage {
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return ctx.makeImage()!
  }

  @Test func heicBecomesJpeg() async throws {
    let root = TestFileRoot()
    let p = try await prepare(try FixtureLoader.url("Images/sample.heic"), root: root)
    #expect(p.mimeType == "image/jpeg")
    #expect(p.url.pathExtension == "jpg")
    #expect((p.pixelWidth, p.pixelHeight) == (640, 480))
    #expect(p.longEdgeSetting == 2048)
    #expect(p.url.lastPathComponent.hasSuffix("-2048.jpg"))
    let info = try ImageInspector.inspect(url: p.url)
    #expect(info.utType == UTType.jpeg.identifier)
    #expect(p.byteCount == (try Data(contentsOf: p.url)).count)
  }

  @Test func heicWithAlphaBecomesJpeg() async throws {
    let root = TestFileRoot()
    let source = try write(ImageFactory.encode(Self.transparentWithSquare(), type: .heic), "alpha.heic", root: root)
    let p = try await prepare(source, root: root)
    #expect(p.mimeType == "image/jpeg")
    let info = try ImageInspector.inspect(url: p.url)
    #expect(!info.hasAlpha)
    // The transparent corner is now white.
    let corner = try pixel(p.url, x: 1, y: 1)
    #expect(corner[0] > 240 && corner[1] > 240 && corner[2] > 240)
    let center = try pixel(p.url, x: 32, y: 24)
    #expect(center[0] > 200 && center[1] < 60)
  }

  @Test(.serialized, arguments: [1536, 2048, 3072, 4096])
  func longEdgeCapped(edge: Int) async throws {
    let root = TestFileRoot()
    // An 8064×6048 (48 MP) source.
    let source = root.file("48mp.jpg")
    try ImagePreprocessor.write(ImageFactory.cgImage(width: 8064, height: 6048, seed: edge), to: source, type: .jpeg, quality: 0.8)
    let start = ContinuousClock.now
    let p = try await prepare(source, edge: edge, root: root)
    let duration = ContinuousClock.now - start
    #expect(duration < .seconds(3))
    #expect(max(p.pixelWidth, p.pixelHeight) == edge)
    #expect(abs(Double(p.pixelWidth) / Double(p.pixelHeight) - 4.0 / 3.0) < 0.01)
    #expect(p.longEdgeSetting == edge)
  }

  @Test func shrunkFileSurvivesALaterPrepareAtTheSameEdge() async throws {
    let root = TestFileRoot()
    let source = root.file("big.jpg")
    try ImagePreprocessor.write(ImageFactory.cgImage(width: 4000, height: 3000, seed: 7), to: source, type: .jpeg, quality: 0.8)
    let id = UUID()
    let dir = root.directory("prepared")
    let prepared = try await ImagePreprocessor.prepare(source: source, maxLongEdge: 2048, destinationDir: dir, id: id)
    // The budget step shrinks it to a 1536 px long edge; an older request records that file.
    let shrunk = try await ImagePreprocessor.shrink(prepared, factor: 0.75)
    #expect(max(shrunk.pixelWidth, shrunk.pixelHeight) == 1536)
    #expect(shrunk.url.lastPathComponent == "\(id.uuidString)-s1536.jpg")
    let before = try Data(contentsOf: shrunk.url)
    // Later the max long edge is set to 1536 and the same upload is prepared again.
    let again = try await ImagePreprocessor.prepare(source: source, maxLongEdge: 1536, destinationDir: dir, id: id)
    #expect(again.url != shrunk.url)
    #expect(try Data(contentsOf: shrunk.url) == before)
    // A shrink of a shrunk file is named from the same stem.
    let twice = try await ImagePreprocessor.shrink(shrunk, factor: 0.75)
    #expect(twice.url.lastPathComponent == "\(id.uuidString)-s1152.jpg")
    #expect(ImagePreprocessor.stem(of: twice.url) == id.uuidString)
  }

  @Test func cancelledPreparationWritesNothing() async throws {
    let root = TestFileRoot()
    let dir = root.directory("prepared")
    let result = await Task {
      // The tray item was removed: its task is cancelled before the work gets far.
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ImagePreprocessor.prepare(
        source: try FixtureLoader.url("Images/sample.heic"), maxLongEdge: 2048, destinationDir: dir, id: UUID())
    }.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).isEmpty)
  }

  @Test func neverUpscales() async throws {
    let root = TestFileRoot()
    let p = try await prepare(try FixtureLoader.url("Images/tiny_16x9.png"), edge: 4096, root: root)
    #expect((p.pixelWidth, p.pixelHeight) == (32, 18))
    #expect(p.mimeType == "image/jpeg")  // a PNG without alpha
  }

  @Test func orientationApplied() async throws {
    let root = TestFileRoot()
    let source = try FixtureLoader.url("Images/rotated_exif6.jpg")
    #expect(try ImageInspector.inspect(url: source).orientation == 6)
    let p = try await prepare(source, root: root)
    #expect((p.pixelWidth, p.pixelHeight) == (300, 400))
    #expect(try ImageInspector.inspect(url: p.url).orientation == 1)
    // The white mark at the stored top-left ends up at the top-right once rotated 90° clockwise.
    let topRight = try pixel(p.url, x: 290, y: 10)
    #expect(topRight[0] > 230 && topRight[1] > 230 && topRight[2] > 230)
  }

  @Test func gpsAndExifStripped() async throws {
    let root = TestFileRoot()
    var props: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W",
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:10:16 09:41:00", kCGImagePropertyExifUserComment: "secret place",
      ],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
    ]
    props[kCGImageDestinationLossyCompressionQuality] = 0.8
    let source = try write(ImageFactory.encode(ImageFactory.cgImage(width: 64, height: 48), type: .jpeg, properties: props), "gps.jpg", root: root)
    let sourceProps = try #require(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil) as? [CFString: Any])
    #expect(sourceProps[kCGImagePropertyGPSDictionary] != nil)

    let p = try await prepare(source, root: root)
    let out = try #require(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(p.url as CFURL, nil)!, 0, nil) as? [CFString: Any])
    #expect(out[kCGImagePropertyGPSDictionary] == nil)
    let exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
    #expect(exif[kCGImagePropertyExifUserComment] == nil)
    let tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    #expect(tiff[kCGImagePropertyTIFFMake] == nil)
    #expect(tiff[kCGImagePropertyTIFFModel] == nil)
  }

  @Test func pngWithAlphaKeepsPNG() async throws {
    let root = TestFileRoot()
    let source = try write(ImageFactory.encode(Self.transparentWithSquare(), type: .png), "alpha.png", root: root)
    let p = try await prepare(source, root: root)
    #expect(p.mimeType == "image/png")
    #expect(p.url.pathExtension == "png")
    #expect(try ImageInspector.inspect(url: p.url).hasAlpha)
    #expect(try pixel(p.url, x: 1, y: 1)[3] == 0)
  }

  @Test func gifToJpeg() async throws {
    let root = TestFileRoot()
    let source = try write(ImageFactory.gif(width: 40, height: 30), "anim.gif", root: root)
    let p = try await prepare(source, root: root)
    #expect(p.mimeType == "image/jpeg")
    #expect((p.pixelWidth, p.pixelHeight) == (40, 30))
  }

  @Test(.enabled(if: (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.webP.identifier)))
  func webpToJpeg() async throws {
    let root = TestFileRoot()
    let source = try write(ImageFactory.encode(ImageFactory.cgImage(width: 40, height: 30), type: .webP), "x.webp", root: root)
    let p = try await prepare(source, root: root)
    #expect(p.mimeType == "image/jpeg")
  }

  @Test func damagedImageThrows() async throws {
    let root = TestFileRoot()
    let source = try write(Data("not an image at all".utf8), "bad.jpg", root: root)
    await #expect(throws: UnsupportedImageError()) { try await prepare(source, root: root) }
    #expect(UnsupportedImageError().localizedDescription == "Unsupported or damaged image")
    #expect(throws: UnsupportedImageError()) { try ImageInspector.inspect(data: Data([0, 1, 2])) }
  }

  @Test func inspectorReadsWithoutDecoding() throws {
    let info = try ImageInspector.inspect(url: try FixtureLoader.url("Images/rotated_exif6.jpg"))
    #expect(info.mimeType == "image/jpeg")
    #expect((info.pixelWidth, info.pixelHeight) == (400, 300))
    #expect((info.orientedWidth, info.orientedHeight) == (300, 400))
    #expect(!info.hasAlpha)
    #expect(info.frameCount == 1)
    let heic = try ImageInspector.inspect(url: try FixtureLoader.url("Images/sample.heic"))
    #expect(heic.mimeType == "image/heic")
  }
}
