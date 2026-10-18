// Records the README's clips from the built app:
//
//   scripts/build.sh && swift scripts/make-video.swift            every scene
//   scripts/build.sh && swift scripts/make-video.swift full tour  just these
//
// For each scene, MusicNotch acts out a script with made-up tracks (`-demo <scene>`, see
// Sources/MusicNotch/DemoScene.swift). ScreenCaptureKit records only MusicNotch's own windows,
// and each frame is placed on a backdrop like the top of a MacBook screen, with the camera
// housing and a drawn pointer that follows the script. Writes docs/demo.gif (the tour, at the
// top of the README) and docs/clips/<scene>.gif, plus docs/demo.mp4 for sharing (large, so not
// committed). GitHub won't play a video from the repository, hence GIFs.
//
// Needs the Screen Recording permission for the terminal it runs in, and a MacBook with a
// notch. A running MusicNotch is quit first; reopen it afterwards.
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

// The system cursor's artwork only loads once there's an application object.
_ = NSApplication.shared

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let app = root.appendingPathComponent("build/MusicNotch.app/Contents/MacOS/MusicNotch")
let clockFile = FileManager.default.temporaryDirectory.appendingPathComponent("musicnotch-demo-clock")

guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
      let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
else { fatalError("Run this on a MacBook with a notch.") }
let notchHeight = screen.safeAreaInsets.top
let notchWidth = screen.frame.width - left.width - right.width
let scale = screen.backingScaleFactor
let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

let fps = 60.0
let gifFPS = 20.0
/// Seconds recorded before a scene starts.
let preRoll = 0.8
/// Width of the area recorded around the notch, in points.
let notchCanvasWidth: CGFloat = 820

/// Settings for the scenes, as launch arguments, which are never saved: the defaults, but
/// with the bars always moving, and nothing (a full-screen app, the menu bar icon) in the way.
let settings = [
    "openAnimation": "<integer>0</integer>", "spaceSwitchAnimation": "<integer>1</integer>",
    "equalizerAnimation": "<integer>0</integer>", "notchStyle": "<integer>1</integer>",
    "notchOpenTrigger": "<integer>0</integer>", "showBesideNotch": "<true/>", "showTrackPeek": "<true/>",
    "showShuffleRepeat": "<true/>", "showSearch": "<true/>", "showArtwork": "<true/>",
    "showProgressBar": "<true/>", "lowResourceMode": "<false/>", "hideDuringSwipes": "<false/>",
    "hideInFullScreen": "<integer>0</integer>", "showMenuBarIcon": "<false/>", "settingsTab": "<integer>0</integer>",
    "updateBatching": "<integer>150</integer>", "openFromCameraOnly": "<true/>", "clickArtworkOpensApp": "<true/>",
    "showOnExternalDisplays": "<false/>", "notchTheme": "<integer>1</integer>", "accentColour": "<integer>0</integer>", "followLowPowerMode": "<false/>",
]
/// The Settings clip shows every setting at its default.
let settingsDefaults = [
    "equalizerAnimation": "<integer>1</integer>", "hideInFullScreen": "<integer>0</integer>",
    "showMenuBarIcon": "<true/>", "followLowPowerMode": "<true/>", "notchStyle": "<integer>1</integer>",
    "notchTheme": "<integer>1</integer>",
]

// MARK: The scenes

/// A clip. Its timings follow the scene's steps in DemoScene.swift; keep the two in step.
struct Scene {
    let name: String
    /// Seconds recorded after the scene starts.
    let length: Double
    /// Height of the notch scenes' canvas, in points.
    var height: CGFloat = 270
    /// The pointer: seconds from the scene's start, and points from the top centre of the
    /// screen (or the Settings window's top left). Empty: no pointer.
    var path: [(t: Double, x: CGFloat, y: CGFloat)] = []
    var clicks: [Double] = []
    /// When the mouse button is held down, dragging.
    var drags: [ClosedRange<Double>] = []
    /// Recorded around the Settings window rather than the notch.
    var isSettings = false
    /// The README's main clip, also written as an MP4.
    var isTour = false
    /// Settings of its own, on top of `settings`.
    var extraSettings: [String: String] = [:]

    var output: URL {
        root.appendingPathComponent(isTour ? "docs/demo.gif" : "docs/clips/\(name).gif")
    }
}

// Points in the Full panel, from the top centre of the screen: the camera area (4, 15), the
// progress bar at y 123 from x -124 to 124, the controls row at y 161 (search -157,
// shuffle -108, play 0, repeat 108), the first search result (-40, 101), and the app icons
// beside the camera (Spotify -170, Chrome -148, Music 170; y 16).
let park = (x: CGFloat(250), y: CGFloat(224))
let scenes: [Scene] = [
    // Compact, the default style, from the top centre of the screen: the controls row at y 62
    // (shuffle -2, play 47, repeat 96, search 125, volume 155, for Music or Spotify), the
    // first search result (-40, 101), and for an app on a call, microphone (60, 62) and
    // deafen (88, 62).
    Scene(name: "tour", length: 13.0, height: 300,
          path: [(-1, 250, 236), (0.4, 250, 236), (1.2, 4, 15), (2.1, 4, 15), (2.8, 47, 62), (4.9, 47, 62),
                 (5.7, 125, 62), (6.4, 125, 62), (7.0, 150, 75), (8.2, 150, 75), (8.9, -40, 101),
                 (9.4, -40, 101), (10.4, 250, 236)],
          clicks: [3.0, 4.6, 6.2, 9.2], isTour: true),
    Scene(name: "closed", length: 4.8, height: 110),
    Scene(name: "minimal", length: 5.2, height: 130,
          path: [(-1, 250, 92), (0.3, 250, 92), (1.1, 4, 15), (1.6, 4, 15), (2.2, 103, 16), (2.8, 103, 16),
                 (3.8, 250, 92)],
          clicks: [2.5]),
    Scene(name: "compact", length: 6.4, height: 160,
          path: [(-1, 250, 120), (0.3, 250, 120), (1.1, 4, 15), (1.6, 4, 15), (2.4, 47, 62), (4.6, 47, 62),
                 (5.4, 250, 120)],
          clicks: [2.8, 4.2]),
    Scene(name: "full", length: 8.2,
          path: [(-1, park.x, park.y), (0.3, park.x, park.y), (1.1, 4, 15), (1.7, 4, 15), (2.6, -30, 123),
                 (2.8, -30, 123), (3.8, 55, 123), (3.9, 55, 123), (4.7, -108, 161), (5.2, -108, 161),
                 (5.6, 108, 161), (6.2, 108, 161), (7.0, park.x, park.y)],
          clicks: [5.0, 5.9], drags: [2.75...3.9]),
    // Eight apps: four icons each side of the camera, 22 pt apart, the outermost 175 pt out
    // (YouTube -153, Spotify -175, Teams 175).
    Scene(name: "sources", length: 8.4, height: 160,
          path: [(-1, 250, 120), (0.3, 250, 120), (1.1, 4, 15), (1.7, 4, 15), (2.6, -153, 16),
                 (3.4, -153, 16), (4.2, 175, 16), (5.0, 175, 16), (5.8, -175, 16), (6.6, -175, 16),
                 (7.4, 250, 120)],
          clicks: [3.0, 4.6, 6.2]),
    Scene(name: "search", length: 8.6,
          path: [(-1, park.x, park.y), (0.3, park.x, park.y), (1.1, 4, 15), (1.4, 4, 15), (2.1, 125, 62),
                 (2.7, 125, 62), (3.3, 150, 75), (4.3, 150, 75), (4.9, -40, 101), (5.5, -40, 101),
                 (6.4, park.x, park.y)],
          clicks: [2.4, 5.2]),
    Scene(name: "sound", length: 7.0, height: 160,
          path: [(-1, 250, 120), (0.3, 250, 120), (1.1, 4, 15), (1.7, 4, 15), (2.5, 60, 62),
                 (3.0, 60, 62), (3.9, 88, 62), (4.4, 88, 62), (5.4, 250, 120)],
          clicks: [2.8, 4.2]),
    Scene(name: "new-track", length: 4.6, height: 140),
    // Toolbar items from the window's top left: General 48, Notch 104, Appearance 170,
    // Animations 244, Shortcuts 311, Performance 383, About 452; y 50.
    Scene(name: "settings", length: 8.4,
          path: [(-1, 230, 300), (0.4, 230, 300), (1.0, 104, 50), (1.8, 104, 50), (2.4, 170, 50), (3.2, 170, 50),
                 (3.8, 244, 50), (4.6, 244, 50), (5.2, 383, 50), (6.0, 383, 50), (6.6, 452, 50)],
          clicks: [1.4, 2.8, 4.2, 5.6, 7.0], isSettings: true),
]

func pointer(_ scene: Scene, at t: Double) -> (point: CGPoint, pressed: Bool)? {
    guard let last = scene.path.last else { return nil }
    var position = CGPoint(x: last.x, y: last.y)
    for (from, to) in zip(scene.path, scene.path.dropFirst()) where t >= from.t && t <= to.t {
        let linear = to.t > from.t ? (t - from.t) / (to.t - from.t) : 1
        let eased = linear * linear * (3 - 2 * linear)
        position = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
        break
    }
    let pressed = scene.clicks.contains { t >= $0 - 0.06 && t <= $0 + 0.12 } || scene.drags.contains { $0.contains(t) }
    return (position, pressed)
}

// MARK: Drawing

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// A context in points with the origin at the top left, like a screen.
func makeContext(_ size: CGSize) -> CGContext {
    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.translateBy(x: 0, y: size.height * scale)
    context.scaleBy(x: scale, y: -scale)
    context.interpolationQuality = .high
    return context
}

/// The wallpaper, with the camera housing and a few menu bar icons for the notch scenes.
/// `calm` is a gentle two-colour version for GIFs, whose 256 colours would band the full one.
func makeBackdrop(_ size: CGSize, calm: Bool, notch: Bool) -> CGImage {
    let context = makeContext(size)
    if calm {
        context.drawLinearGradient(gradient([color(0x3B1F7A), color(0x7A1F5C)]), start: .zero,
                                   end: CGPoint(x: size.width, y: size.height), options: [])
    } else {
        let height: CGFloat = 460
        context.drawLinearGradient(gradient([color(0x1E1B4B), color(0x5B21B6), color(0xBE185D), color(0xF97316)]),
                                   start: .zero, end: CGPoint(x: size.width, y: height * 1.6),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        for (x, y, radius, hex, alpha) in [(0.15, 0.05, 0.55, 0x22D3EE, 0.35), (0.9, 0.0, 0.45, 0xF472B6, 0.35),
                                           (0.55, 1.0, 0.6, 0xFBBF24, 0.22)] as [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] {
            let center = CGPoint(x: x * size.width, y: y * height)
            context.drawRadialGradient(gradient([color(hex, alpha), color(hex, 0)]), startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius * size.width, options: [])
        }
    }
    guard notch else { return context.makeImage()! }
    let housing = CGRect(x: (size.width - notchWidth) / 2, y: -10, width: notchWidth, height: notchHeight + 10)
    context.addPath(CGPath(roundedRect: housing, cornerWidth: 9, cornerHeight: 9, transform: nil))
    context.setFillColor(color(0x000000))
    context.fillPath()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    var x = size.width - 22
    for symbol in ["battery.75percent", "wifi", "music.note"] {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { continue }
        x -= image.size.width
        image.draw(in: CGRect(x: x, y: (notchHeight - image.size.height) / 2, width: image.size.width, height: image.size.height))
        x -= 16
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

let arrow = NSCursor.arrow
/// Only touched on the main thread.
nonisolated(unsafe) var backdropWindow: BackdropWindow?

/// A window under every other one, so it's only seen by the recording.
final class BackdropWindow: NSWindow {
    init(_ image: CGImage, region: CGRect, on screenFrame: CGRect) {
        let frame = CGRect(x: screenFrame.minX + region.minX, y: screenFrame.maxY - region.maxY,
                           width: region.width, height: region.height)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = CALayerContentsGravity.resize
        contentView = view
        setFrame(frame, display: true)
        orderFrontRegardless()
        CATransaction.flush()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The backdrop, MusicNotch's windows and the pointer, at `time` seconds into the scene.
func compose(_ context: CGContext, size: CGSize, backdrop: CGImage, capture: CGImage?, scene: Scene,
             anchor: CGPoint, time: Double) -> CGImage? {
    for image in [backdrop, capture].compactMap({ $0 }) {
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }
    if let (position, pressed) = pointer(scene, at: time) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let factor: CGFloat = pressed ? 0.85 : 1
        let imageSize = CGSize(width: arrow.image.size.width * factor, height: arrow.image.size.height * factor)
        let origin = CGPoint(x: anchor.x + position.x - arrow.hotSpot.x * factor,
                             y: anchor.y + position.y - arrow.hotSpot.y * factor)
        arrow.image.draw(in: CGRect(origin: origin, size: imageSize))
        NSGraphicsContext.restoreGraphicsState()
    }
    return context.makeImage()
}

// MARK: Capture

/// Keeps the latest frame ScreenCaptureKit delivers.
final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGImage?
    private let images = CIContext()

    var latest: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pixels = buffer.imageBuffer
        else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = images.createCGImage(image, from: image.extent) else { return }
        lock.lock()
        frame = cgImage
        lock.unlock()
    }
}

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

/// Launches MusicNotch on `scene`, records it, and writes its GIF (and MP4 for the tour).
func record(_ scene: Scene) async throws {
    run("/usr/bin/pkill", ["-x", "MusicNotch"])
    try await Task.sleep(for: .seconds(1))
    try? FileManager.default.removeItem(at: clockFile)
    let process = Process()
    process.executableURL = app
    let overrides = settings.merging(scene.isSettings ? settingsDefaults : [:]) { $1 }
        .merging(scene.extraSettings) { $1 }
    process.arguments = ["-demo", scene.name, "-demoClock", clockFile.path]
        + overrides.sorted { $0.key < $1.key }.flatMap { ["-\($0.key)", $0.value] }
    try process.run()
    defer {
        process.terminate()
        process.waitUntilExit()
    }

    // Wait for MusicNotch's windows: the Settings window, or the notch.
    var found: (SCShareableContent, SCRunningApplication, SCWindow?)?
    for _ in 0..<60 where found == nil {
        try await Task.sleep(for: .milliseconds(100))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let musicNotch = content.applications.first(where: { $0.processID == process.processIdentifier })
        else { continue }
        let windows = content.windows.filter { $0.owningApplication?.processID == process.processIdentifier }
        let settingsWindow = windows.first { $0.windowLayer == 0 && $0.frame.width > 300 }
        if scene.isSettings ? settingsWindow != nil : !windows.isEmpty {
            found = (content, musicNotch, settingsWindow)
        }
    }
    guard let (content, musicNotch, settingsWindow) = found,
          let display = content.displays.first(where: { $0.displayID == displayID })
    else { throw NSError(domain: "make-video", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(scene.name): no windows"]) }

    // The area recorded, in screen points from the top left, and where the pointer's
    // coordinates start within it.
    let region: CGRect
    let anchor: CGPoint
    if scene.isSettings, let frame = settingsWindow?.frame {
        // Tall enough for the tallest tab shown; the window grows down from its top.
        region = CGRect(x: frame.minX - 40, y: frame.minY - 40, width: frame.width + 80, height: 700)
        anchor = CGPoint(x: 40, y: 40)
    } else {
        region = CGRect(x: (screen.frame.width - notchCanvasWidth) / 2, y: 0, width: notchCanvasWidth, height: scene.height)
        anchor = CGPoint(x: notchCanvasWidth / 2, y: 0)
    }
    let size = region.size
    let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)

    let configuration = SCStreamConfiguration()
    configuration.sourceRect = region
    configuration.width = pixelWidth
    configuration.height = pixelHeight
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.backgroundColor = .clear
    configuration.showsCursor = false
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    configuration.queueDepth = 8
    var included = [musicNotch]
    // The backdrop in a real window behind the notch, for the glass to blur: the recording
    // leaves out every other window, so otherwise there'd be nothing behind it.
    if !scene.isSettings {
        let image = makeBackdrop(size, calm: true, notch: true), screenFrame = screen.frame
        await MainActor.run { backdropWindow = BackdropWindow(image, region: region, on: screenFrame) }
        try await Task.sleep(for: .milliseconds(300))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let recorder = content.applications.first(where: { $0.processID == getpid() })
        else { throw NSError(domain: "make-video", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(scene.name): no backdrop window"]) }
        included.append(recorder)
    }
    let capture = Capture()
    let stream = SCStream(filter: SCContentFilter(display: display, including: included, exceptingWindows: []),
                          configuration: configuration, delegate: nil)
    try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
    try await stream.startCapture()

    // The scene writes its start time (CACurrentMediaTime) once it begins.
    var start: Double?
    for _ in 0..<200 where start == nil {
        start = (try? String(contentsOf: clockFile, encoding: .utf8)).flatMap(Double.init)
        if start == nil { try await Task.sleep(for: .milliseconds(50)) }
    }
    guard let start else { throw NSError(domain: "make-video", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(scene.name): didn't start"]) }

    // The GIF, and for the tour an MP4 on the full wallpaper.
    let frameCount = Int((preRoll + scene.length) * fps)
    let gifStep = Int(fps / gifFPS)
    try FileManager.default.createDirectory(at: scene.output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: scene.output)
    let gif = CGImageDestinationCreateWithURL(scene.output as CFURL, UTType.gif.identifier as CFString, frameCount / gifStep + 1, nil)!
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let gifFrame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFPS,
                                                    kCGImagePropertyGIFUnclampedDelayTime: 1 / gifFPS]] as CFDictionary
    let gifContext = makeContext(size)
    let gifBackdrop = makeBackdrop(size, calm: true, notch: !scene.isSettings)

    var video: (writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                context: CGContext, backdrop: CGImage)?
    if scene.isTour {
        let url = root.appendingPathComponent("docs/demo.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: pixelWidth, AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoExpectedSourceFrameRateKey: Int(fps)],
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelWidth, kCVPixelBufferHeightKey as String: pixelHeight,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        video = (writer, input, adaptor, makeContext(size), makeBackdrop(size, calm: false, notch: true))
    }

    let firstFrame = start - preRoll
    for index in 0..<frameCount {
        let time = Double(index) / fps
        // Keep pace with the app, a frame behind so the capture has caught up.
        while CACurrentMediaTime() < firstFrame + time + 1 / fps { usleep(1000) }
        let captured = capture.latest
        let sceneTime = time - preRoll

        if index % gifStep == 0,
           let still = compose(gifContext, size: size, backdrop: gifBackdrop, capture: captured, scene: scene,
                               anchor: anchor, time: sceneTime) {
            CGImageDestinationAddImage(gif, still, gifFrame)
        }
        guard let video, let composed = compose(video.context, size: size, backdrop: video.backdrop, capture: captured,
                                                scene: scene, anchor: anchor, time: sceneTime)
        else { continue }
        while !video.input.isReadyForMoreMediaData { usleep(500) }
        var buffer: CVPixelBuffer?
        if let pool = video.adaptor.pixelBufferPool,
           CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: pixelWidth, height: pixelHeight,
                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .draw(composed, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            video.adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
    }

    CGImageDestinationFinalize(gif)
    if let video {
        video.input.markAsFinished()
        await video.writer.finishWriting()
    }
    try await stream.stopCapture()
    await MainActor.run {
        backdropWindow?.close()
        backdropWindow = nil
    }
    try? FileManager.default.removeItem(at: clockFile)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: scene.output.path)[.size] as? Int) ?? 0
    print("  \(scene.name): \(scene.output.path.replacingOccurrences(of: root.path + "/", with: "")) (\(bytes / 1024) KB)")
}

guard FileManager.default.isExecutableFile(atPath: app.path) else { fatalError("Build the app first: scripts/build.sh") }
let requested = Set(CommandLine.arguments.dropFirst())
for scene in scenes where requested.isEmpty || requested.contains(scene.name) {
    do {
        try await record(scene)
    } catch {
        print("  \(scene.name) failed: \(error.localizedDescription)")
    }
}
