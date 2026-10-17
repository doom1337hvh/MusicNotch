// Makes the README screenshots in docs/screenshots from the built app:
//
//   scripts/build.sh && swift scripts/make-screenshots.swift
//
// For each shot it launches MusicNotch with made-up tracks (`-demo <shot>`, see
// Sources/MusicNotch/DemoShot.swift), captures only MusicNotch's own window, and places it on
// a backdrop like the top of a MacBook screen. It needs the Screen Recording permission for
// the terminal it runs in, and a MacBook with a notch. A running MusicNotch is quit first.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let app = root.appendingPathComponent("build/MusicNotch.app/Contents/MacOS/MusicNotch")
let output = root.appendingPathComponent("docs/screenshots")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("musicnotch-shots")

/// The notch height and display scale, from the built-in display.
guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
    fatalError("Run this on a MacBook with a notch.")
}
let menuBarHeight = screen.safeAreaInsets.top
let scale = screen.backingScaleFactor

/// Width of the backdrop, in points: the middle of the screen, around the notch.
let canvasWidth: CGFloat = 820
/// The backdrop's wallpaper is drawn this tall, so every shot shows the same "screen".
let wallpaperHeight: CGFloat = 460

struct Shot {
    let name: String
    var arguments: [String] = []
    /// The Settings window rather than the notch.
    var isSettings = false
}

let shots = [
    Shot(name: "closed"),
    Shot(name: "minimal"),
    Shot(name: "compact"),
    Shot(name: "full"),
    Shot(name: "sources"),
    Shot(name: "new-track"),
    Shot(name: "search"),
    Shot(name: "settings", arguments: ["-settingsTab", "1"], isSettings: true),
]

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

/// The largest on-screen window of `pid` at `layer`.
func window(of pid: pid_t, layer: Int) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list
        .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == layer }
        .max { area($0) < area($1) }
        .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
}

func area(_ window: [String: Any]) -> CGFloat {
    let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
        .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
    return bounds.width * bounds.height
}

/// Launches the app on `shot`, captures its window, and quits it.
func capture(_ shot: Shot) -> CGImage? {
    let process = Process()
    process.executableURL = app
    process.arguments = ["-demo", shot.name] + shot.arguments
    try? process.run()
    Thread.sleep(forTimeInterval: 2.5)  // launch, show, and finish opening
    defer {
        process.terminate()
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
    }
    let layer = shot.isSettings ? 0 : Int(CGWindowLevelForKey(.mainMenuWindow)) + 3
    guard let id = window(of: process.processIdentifier, layer: layer) else {
        print("  no window for \(shot.name)")
        return nil
    }
    let file = scratch.appendingPathComponent("\(shot.name).png")
    // -o leaves out the window shadow; the notch has none, the Settings window keeps its own.
    run("/usr/sbin/screencapture", ["-x"] + (shot.isSettings ? [] : ["-o"]) + ["-l", String(id), file.path])
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// How far down the image has visible pixels, in pixels.
func visibleBottom(of image: CGImage) -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Rows are stored top first.
    for row in stride(from: height - 1, through: 0, by: -1) {
        for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 8 {
            return row + 1
        }
    }
    return height
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// A soft, colourful wallpaper, `size` in points, drawn into a top-left-origin context.
func drawWallpaper(in context: CGContext, size: CGSize) {
    let height = max(size.height, wallpaperHeight)
    context.drawLinearGradient(gradient([color(0x1E1B4B), color(0x5B21B6), color(0xBE185D), color(0xF97316)]),
                               start: .zero, end: CGPoint(x: size.width, y: height * 1.6),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    for (x, y, radius, hex, alpha) in [(0.15, 0.05, 0.55, 0x22D3EE, 0.35), (0.9, 0.0, 0.45, 0xF472B6, 0.35),
                                       (0.55, 1.0, 0.6, 0xFBBF24, 0.22)] as [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] {
        let center = CGPoint(x: x * size.width, y: y * height)
        context.drawRadialGradient(gradient([color(hex, alpha), color(hex, 0)]),
                                   startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: radius * size.width, options: [])
    }
}

/// A few status icons at the right of the menu bar, including MusicNotch's ♪.
func drawMenuBarIcons(width: CGFloat) {
    var x = width - 22
    for symbol in ["battery.75percent", "wifi", "music.note"] {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { continue }
        let size = image.size
        x -= size.width
        image.draw(in: CGRect(x: x, y: (menuBarHeight - size.height) / 2, width: size.width, height: size.height))
        x -= 16
    }
}

/// Places a captured window on the backdrop and writes the PNG.
func compose(_ image: CGImage, shot: Shot) {
    let windowSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let size: CGSize
    if shot.isSettings {
        size = CGSize(width: windowSize.width + 80, height: windowSize.height + 60)
    } else {
        let bottom = CGFloat(visibleBottom(of: image)) / scale
        size = CGSize(width: canvasWidth, height: max(bottom + 64, 100))
    }
    let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
    guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    // Work in points with the origin at the top left, like a screen.
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.clip()
    drawWallpaper(in: context, size: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    if !shot.isSettings { drawMenuBarIcons(width: size.width) }
    NSGraphicsContext.restoreGraphicsState()

    // The window: hanging from the top centre for the notch, centred for Settings.
    let origin = shot.isSettings
        ? CGPoint(x: (size.width - windowSize.width) / 2, y: (size.height - windowSize.height) / 2)
        : CGPoint(x: (size.width - windowSize.width) / 2, y: 0)
    context.saveGState()
    context.translateBy(x: origin.x, y: origin.y + windowSize.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: windowSize))
    context.restoreGState()

    guard let result = context.makeImage() else { return }
    let file = output.appendingPathComponent("\(shot.name).png")
    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, result, [kCGImagePropertyDPIWidth: 72 * scale,
                                                     kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    CGImageDestinationFinalize(destination)
    print("  wrote docs/screenshots/\(shot.name).png (\(pixelWidth)×\(pixelHeight))")
}

guard FileManager.default.isExecutableFile(atPath: app.path) else {
    fatalError("Build the app first: scripts/build.sh")
}
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
run("/usr/bin/pkill", ["-x", "MusicNotch"])
Thread.sleep(forTimeInterval: 1)

let requested = Set(CommandLine.arguments.dropFirst())
for shot in shots where requested.isEmpty || requested.contains(shot.name) {
    print(shot.name)
    if let image = capture(shot) { compose(image, shot: shot) }
}
try? FileManager.default.removeItem(at: scratch)
