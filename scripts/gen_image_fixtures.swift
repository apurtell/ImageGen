// Generates binary image test fixtures for automated test suites:
//   xcrun swift scripts/gen_image_fixtures.swift ImageGenTests/Fixtures/Images
// With `--large <path>`, outputs an 8064×6048 JPEG fixture for manual display testing.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func gradient(width: Int, height: Int, from: (CGFloat, CGFloat, CGFloat), to: (CGFloat, CGFloat, CGFloat),
              mark: Bool = true) -> CGImage {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let colors = [CGColor(srgbRed: from.0, green: from.1, blue: from.2, alpha: 1),
                CGColor(srgbRed: to.0, green: to.1, blue: to.2, alpha: 1)] as CFArray
  let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
  ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
  if mark {
    // Renders an asymmetric corner indicator to detect coordinate orientation discrepancies.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height - max(1, height / 4), width: max(1, width / 3), height: max(1, height / 4)))
  }
  return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
  guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
    fatalError("cannot create \(type.identifier) destination for \(url.path)")
  }
  CGImageDestinationAddImage(dest, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
  print("\(url.lastPathComponent): \(image.width)×\(image.height), \(size) bytes")
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--large" {
  guard let path = args.dropFirst().first else { fatalError("usage: --large <path>") }
  write(gradient(width: 8064, height: 6048, from: (0.1, 0.3, 0.6), to: (0.9, 0.6, 0.2)),
        to: URL(fileURLWithPath: path), type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
  exit(0)
}
guard let dir = args.first else { fatalError("usage: gen_image_fixtures.swift <output dir> | --large <path>") }
let out = URL(fileURLWithPath: dir, isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

write(gradient(width: 640, height: 480, from: (0.15, 0.35, 0.75), to: (0.95, 0.55, 0.25)),
      to: out.appendingPathComponent("sample.heic"), type: .heic,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.6])
// Configured as 400×300 with EXIF orientation 6 (requiring 90° clockwise rotation for upright display).
write(gradient(width: 400, height: 300, from: (0.2, 0.6, 0.3), to: (0.9, 0.9, 0.3)),
      to: out.appendingPathComponent("rotated_exif6.jpg"), type: .jpeg,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.7, kCGImagePropertyOrientation: 6,
                   kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6]])
write(gradient(width: 32, height: 18, from: (0.0, 0.2, 0.5), to: (1.0, 0.8, 0.4), mark: false),
      to: out.appendingPathComponent("tiny_16x9.png"), type: .png)
write(gradient(width: 16, height: 16, from: (0.6, 0.1, 0.1), to: (0.1, 0.1, 0.6), mark: false),
      to: out.appendingPathComponent("tiny_square.jpg"), type: .jpeg,
      properties: [kCGImageDestinationLossyCompressionQuality: 0.8])
