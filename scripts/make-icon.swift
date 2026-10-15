// Builds Resources/AppIcon.icns from design/Hushnote_AppIcon.svg.
// Run from the repository root after the artwork changes: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("design/Hushnote_AppIcon.svg")
let output = root.appendingPathComponent("Resources/AppIcon.icns")
guard let art = NSImage(contentsOf: source) else { fatalError("Could not read \(source.path)") }

// The artwork's rounded square spans x 40–1215, y 65–1240 of a 1254 x 1305 canvas.
// macOS places the icon body at 824 px inside a 1024 px canvas, so map that square onto it.
let square = NSRect(x: 40, y: 65, width: 1175, height: 1175)
let body: CGFloat = 824, canvas: CGFloat = 1024

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let unit = CGFloat(pixels) / canvas
    let scale = body / square.width * unit
    let margin = (canvas - body) / 2 * unit
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    // SVG y runs down; AppKit's runs up. The square has equal top and bottom margins, so the offset is symmetric.
    art.draw(in: NSRect(x: margin - square.minX * scale, y: margin - (art.size.height - square.maxY) * scale,
                        width: art.size.width * scale, height: art.size.height * scale))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
