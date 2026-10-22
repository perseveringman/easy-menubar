import AppKit
import CoreGraphics
import Foundation

// Draws the app icon: a macOS-style squircle with the eye-slash glyph that
// also serves as the menu bar button.

let side = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

let inset = CGFloat(side) * 0.07
let rect = CGRect(x: inset, y: inset, width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
let radius = rect.width * 0.2237
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

context.saveGState()
context.addPath(path)
context.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 0.42, green: 0.47, blue: 0.56, alpha: 1),
        CGColor(srgbRed: 0.17, green: 0.20, blue: 0.26, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY),
    options: []
)
context.restoreGState()

// The glyph, rendered from the SF Symbol.
let symbol = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)!
let configuration = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular)
let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
if let cgImage = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let glyphSide = CGFloat(side) * 0.5
    let glyphRect = CGRect(
        x: rect.midX - glyphSide / 2,
        y: rect.midY - glyphSide / 2,
        width: glyphSide,
        height: glyphSide
    )
    context.saveGState()
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    // Draw the symbol as a template image so it takes the fill colour.
    context.clip(to: glyphRect, mask: cgImage)
    context.fill(glyphRect)
    context.restoreGState()
}

guard let image = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
