// Makes the Mac app icon from a picture of a rounded-square icon (e.g. a generated image, often a JPEG with the
// transparency checkerboard painted in around the square).
//   swift scripts/icon-from-image.swift <image> <output.icns>
// The square is found as the bounding box of the colorful (saturated) pixels, so the gray-and-white checkerboard
// and plain margins drop out. It's clipped to the same rounded square, 10% margin and 22.5% corner radius as
// scripts/make-icon.swift, so it sits in the Dock like other Mac icons.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: swift scripts/icon-from-image.swift <image> <output.icns>\n".utf8))
    exit(1)
}

// The square: bounding box of pixels whose channels differ by more than a gray checkerboard's.
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let scan = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
scan.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
var (minX, minY, maxX, maxY) = (width, height, -1, -1)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        if max(r, g, b) - min(r, g, b) > 48 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else { print("No colorful square found in \(args[1])"); exit(1) }
// Rows in the bitmap context run bottom-up; cropping uses top-down image coordinates.
let square = image.cropping(to: CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1))!
print("Square: \(square.width)×\(square.height) px of \(width)×\(height)")

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).addClip()
    context.cgContext.draw(square, in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(args[2])")
