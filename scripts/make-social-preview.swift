// Builds design/social-preview.png (1280 x 640), the image GitHub shows when the repository is shared.
// Run from the repository root: swift scripts/make-social-preview.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let logo = NSImage(contentsOf: root.appendingPathComponent("design/Hushnote_Logo.svg")) else { fatalError("Could not read design/Hushnote_Logo.svg") }

let width = 1280, height = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
context.imageInterpolation = .high
NSGraphicsContext.current = context

let ink = NSColor(srgbRed: 0x1C / 255, green: 0x1B / 255, blue: 0x18 / 255, alpha: 1)
let cream = NSColor(srgbRed: 0xF5 / 255, green: 0xEF / 255, blue: 0xE5 / 255, alpha: 1)
ink.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()

// Logo on the left, optically centred; text block to its right. Everything stays inside GitHub's 40 px safe margin.
let logoHeight: CGFloat = 250, logoWidth = logoHeight * logo.size.width / logo.size.height
let logoX: CGFloat = 190, logoY = (CGFloat(height) - logoHeight) / 2
logo.draw(in: NSRect(x: logoX, y: logoY, width: logoWidth, height: logoHeight))

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, x: CGFloat, y: CGFloat, mono: Bool = false, tracking: CGFloat = 0) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: tracking]).draw(at: NSPoint(x: x, y: y))
}
let textX = logoX + logoWidth + 72
draw("ON-DEVICE MEETING RECORDER", size: 19, weight: .medium, color: cream.withAlphaComponent(0.55), x: textX + 4, y: 390, mono: true, tracking: 2.4)
draw("Hushnote", size: 118, weight: .semibold, color: cream, x: textX - 4, y: 250, tracking: -2)
draw("Meeting notes, made on your Mac.", size: 30, weight: .regular, color: cream.withAlphaComponent(0.72), x: textX, y: 196)
NSGraphicsContext.restoreGraphicsState()

let output = root.appendingPathComponent("design/social-preview.png")
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path)")
