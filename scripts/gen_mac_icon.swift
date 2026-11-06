// Generates macOS icon asset variations from the base iOS icon and registers them in the asset catalog.
// Usage: xcrun swift scripts/gen_mac_icon.swift
// Renders the icon artwork within macOS standard grid proportions: an 824x824 rounded rectangle (radius 185)
// centered on a 1024x1024 canvas with drop shadow.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let setURL = URL(fileURLWithPath: "ImageGen/Resources/Assets.xcassets/AppIcon.appiconset")
let source = CGImageSourceCreateWithURL(setURL.appendingPathComponent("AppIcon.png") as CFURL, nil)
guard let source, let art = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
  FileHandle.standardError.write(Data("error: cannot read AppIcon.png\n".utf8))
  exit(1)
}

func render(pixels: Int) -> CGImage {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  let k = CGFloat(pixels) / 1024
  let rect = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
  let path = CGPath(roundedRect: rect, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.3))
  ctx.addPath(path)
  ctx.setFillColor(CGColor(gray: 0, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.draw(art, in: rect)
  return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
}

var entries = ["    { \"filename\" : \"AppIcon.png\", \"idiom\" : \"universal\", \"platform\" : \"ios\", \"size\" : \"1024x1024\" }"]
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "mac_\(points)@\(scale)x.png"
    write(render(pixels: points * scale), to: setURL.appendingPathComponent(name))
    entries.append("    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
  }
}
let json = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(to: setURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
