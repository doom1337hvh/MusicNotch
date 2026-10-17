// Draws MusicNotch's app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// A rounded square in the macOS icon grid, with the notch hanging from its top edge,
// showing album art and equalizer bars like the app does.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func drawIcon(in context: CGContext) {
    // Core Graphics' origin is bottom-left; flip so y grows downward like the layout below.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    // The body: 824 pt with a continuous-looking corner, per Apple's icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.drawLinearGradient(gradient([color(0x4C1D95), color(0x9D174D), color(0xF97316)]),
                               start: CGPoint(x: body.minX, y: body.minY),
                               end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    // A soft glow under the notch, like light spilling from the screen.
    context.drawRadialGradient(gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)]),
                               startCenter: CGPoint(x: 512, y: 330), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 330), endRadius: 420, options: [])

    // The notch, flush with the top edge, rounded at the bottom.
    // Narrower than the body's flat top edge, so its sides drop straight down like the real one.
    let notch = CGRect(x: 512 - 220, y: body.minY - 40, width: 440, height: 40 + 214)
    context.addPath(CGPath(roundedRect: notch, cornerWidth: 92, cornerHeight: 92, transform: nil))
    context.setFillColor(color(0x000000))
    context.fillPath()

    // Album art on the left.
    let art = CGRect(x: notch.minX + 54, y: body.minY + 52, width: 118, height: 118)
    context.saveGState()
    context.addPath(CGPath(roundedRect: art, cornerWidth: 28, cornerHeight: 28, transform: nil))
    context.clip()
    context.drawLinearGradient(gradient([color(0xFDE047), color(0xF97316), color(0xDB2777)]),
                               start: CGPoint(x: art.minX, y: art.minY),
                               end: CGPoint(x: art.maxX, y: art.maxY), options: [])
    context.restoreGState()

    // Equalizer bars on the right, centred on the artwork.
    let heights: [CGFloat] = [56, 106, 80, 42]
    let barWidth: CGFloat = 22
    let gap: CGFloat = 15
    var x = notch.maxX - 54 - CGFloat(heights.count) * barWidth - CGFloat(heights.count - 1) * gap
    context.setFillColor(color(0xFFFFFF))
    for height in heights {
        let bar = CGRect(x: x, y: art.midY - height / 2, width: barWidth, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        context.fillPath()
        x += barWidth + gap
    }

    // A large note below, so the icon reads as music even at small sizes.
    let note = NSAttributedString(string: "♪", attributes: [
        .font: NSFont.systemFont(ofSize: 430, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ])
    let noteSize = note.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    note.draw(at: CGPoint(x: 512 - noteSize.width / 2, y: 645 - noteSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
}

func png(size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    context.interpolationQuality = .high
    drawIcon(in: context)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
