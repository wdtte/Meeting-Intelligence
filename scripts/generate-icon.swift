import AppKit
import Foundation

// Render the same system waveform used in the sidebar; no external artwork or
// image-generation dependency is needed. Keep the iconset reproducible.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, dimension) in variants {
    let size = CGFloat(dimension)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let rect = NSRect(x: size * 0.10, y: size * 0.10, width: size * 0.80, height: size * 0.80)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
    let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.94, alpha: 1), ending: NSColor(calibratedWhite: 0.86, alpha: 1))!
    gradient.draw(in: path, angle: 90)
    NSColor(calibratedWhite: 1, alpha: 0.65).setStroke()
    path.lineWidth = max(0.5, size * 0.0015); path.stroke()
    let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Intelligence")!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0.16, alpha: 1)])))!
    let ratio = symbol.size.width / symbol.size.height
    let height = size * 0.46
    let width = height * ratio
    symbol.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height),
                from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
    if dimension == 1024 { try data.write(to: output.appendingPathComponent("AppIcon.png")) }
}
print("Rendered \(iconset.path)")
