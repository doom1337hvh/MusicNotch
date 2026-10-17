// Records the README demo video from the built app:
//
//   scripts/build.sh && swift scripts/make-video.swift
//
// MusicNotch plays a scripted tour with made-up tracks (`-demo tour`, see DemoShot.tourSteps).
// ScreenCaptureKit records only MusicNotch's own windows around the notch, and each frame is
// placed on the same backdrop as the screenshots (scripts/make-screenshots.swift), with the
// camera housing and a drawn pointer that follows the tour. Writes docs/demo.gif (for the
// README, where GitHub won't play a video from the repository) and docs/demo.mp4 (for posts;
// it's large, so it isn't committed).
//
// Needs the Screen Recording permission for the terminal it runs in, and a MacBook with a
// notch. A running MusicNotch is quit first.
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

// The system cursor's artwork only loads once there's an application object.
_ = NSApplication.shared

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let app = root.appendingPathComponent("build/MusicNotch.app/Contents/MacOS/MusicNotch")
let mp4URL = root.appendingPathComponent("docs/demo.mp4")
let gifURL = root.appendingPathComponent("docs/demo.gif")
let clockFile = FileManager.default.temporaryDirectory.appendingPathComponent("musicnotch-tour-clock")

guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
      let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
else { fatalError("Run this on a MacBook with a notch.") }
let notchHeight = screen.safeAreaInsets.top
let notchWidth = screen.frame.width - left.width - right.width
let scale = screen.backingScaleFactor
let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

/// The recorded area around the notch, in points.
let canvas = CGSize(width: 820, height: 300)
let pixelWidth = Int(canvas.width * scale), pixelHeight = Int(canvas.height * scale)
let fps = 60.0
let gifFPS = 20.0
/// Seconds recorded before the tour starts, and the tour's length (DemoShot.tourSteps ends
/// with a new-track peek that closes by itself at about 12.1 s).
let preRoll = 0.8
let tourLength = 13.0

/// The tour's settings, as launch arguments, which are never saved.
let settings = [
    "-openAnimation", "<integer>0</integer>", "-equalizerAnimation", "<integer>0</integer>",
    "-notchStyle", "<integer>2</integer>", "-notchOpenTrigger", "<integer>0</integer>",
    "-showBesideNotch", "<true/>", "-showTrackPeek", "<true/>", "-showShuffleRepeat", "<true/>",
    "-showSearch", "<true/>", "-showArtwork", "<true/>", "-showProgressBar", "<true/>",
    "-lowResourceMode", "<false/>", "-hideDuringSwipes", "<false/>", "-hideInFullScreen", "<integer>0</integer>",
    "-showMenuBarIcon", "<false/>",
]

// MARK: The pointer

/// Where the pointer is, in seconds from the tour's start and points from the top centre of
/// the screen. It follows DemoShot.tourSteps: the Full panel's play button sits 161 pt down,
/// its search button 157 pt left of it, and the first search result 101 pt down.
let pointerPath: [(t: Double, x: CGFloat, y: CGFloat)] = [
    (-1, 250, 236), (0.4, 250, 236), (1.2, 4, 15),  // to the camera: the notch opens
    (2.1, 4, 15), (2.8, 0, 161),                     // to play/pause
    (4.9, 0, 161), (5.7, -157, 161),                 // to search
    (6.4, -157, 161), (7.0, 120, 128),               // aside while typing
    (8.2, 120, 128), (8.9, -40, 101),                // to the first result
    (9.4, -40, 101), (10.4, 250, 236),               // away, as the notch closes
]
/// When the pointer clicks.
let clicks: [Double] = [3.0, 4.6, 6.2, 9.2]

func pointer(at t: Double) -> (point: CGPoint, pressed: Bool) {
    var position = CGPoint(x: pointerPath.last!.x, y: pointerPath.last!.y)
    for (from, to) in zip(pointerPath, pointerPath.dropFirst()) where t >= from.t && t <= to.t {
        let linear = to.t > from.t ? (t - from.t) / (to.t - from.t) : 1
        let eased = linear * linear * (3 - 2 * linear)
        position = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
        break
    }
    let pressed = clicks.contains { t >= $0 - 0.06 && t <= $0 + 0.12 }
    return (CGPoint(x: canvas.width / 2 + position.x, y: position.y), pressed)
}

// MARK: The backdrop (matches make-screenshots.swift)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// A context in points with the origin at the top left, like a screen.
func makeContext(width: Int, height: Int, scale: CGFloat) -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    context.interpolationQuality = .high
    return context
}

/// `calm` is a gentle two-colour version for the GIF: its 256 colours would band the full
/// wallpaper into blotches.
func makeBackdrop(calm: Bool) -> CGImage {
    let context = makeContext(width: pixelWidth, height: pixelHeight, scale: scale)
    let size = canvas
    let height: CGFloat = 460
    if calm {
        context.drawLinearGradient(gradient([color(0x3B1F7A), color(0x7A1F5C)]), start: .zero,
                                   end: CGPoint(x: size.width, y: size.height), options: [])
    } else {
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
    // The camera housing, black like the real one, so the notch is there even when closed.
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

guard FileManager.default.isExecutableFile(atPath: app.path) else { fatalError("Build the app first: scripts/build.sh") }
run("/usr/bin/pkill", ["-x", "MusicNotch"])
Thread.sleep(forTimeInterval: 1)
try? FileManager.default.removeItem(at: clockFile)

let process = Process()
process.executableURL = app
process.arguments = ["-demo", "tour", "-demoClock", clockFile.path] + settings
try process.run()
print("Recording the tour…")

// Wait for MusicNotch's windows, then capture only them, around the notch.
var foundContent: SCShareableContent?
var foundApp: SCRunningApplication?
for _ in 0..<40 {
    Thread.sleep(forTimeInterval: 0.1)
    foundContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    foundApp = foundContent?.applications.first { $0.processID == process.processIdentifier }
    if foundApp != nil, foundContent?.windows.contains(where: { $0.owningApplication?.processID == process.processIdentifier }) == true {
        break
    }
}
guard let content = foundContent, let musicNotch = foundApp,
      let display = content.displays.first(where: { $0.displayID == displayID })
else {
    process.terminate()
    fatalError("MusicNotch's windows didn't appear.")
}
let filter = SCContentFilter(display: display, including: [musicNotch], exceptingWindows: [])
let configuration = SCStreamConfiguration()
configuration.sourceRect = CGRect(x: (screen.frame.width - canvas.width) / 2, y: 0, width: canvas.width, height: canvas.height)
configuration.width = pixelWidth
configuration.height = pixelHeight
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.colorSpaceName = CGColorSpace.sRGB
configuration.backgroundColor = .clear
configuration.showsCursor = false
configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
configuration.queueDepth = 8

let capture = Capture()
let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
try await stream.startCapture()

// The tour writes its start time (CACurrentMediaTime) once it begins.
var foundStart: Double?
for _ in 0..<100 where foundStart == nil {
    foundStart = (try? String(contentsOf: clockFile, encoding: .utf8)).flatMap(Double.init)
    if foundStart == nil { Thread.sleep(forTimeInterval: 0.05) }
}
guard let tourStart = foundStart else {
    process.terminate()
    fatalError("The tour didn't start.")
}

// MARK: Write the video and the GIF

try? FileManager.default.removeItem(at: mp4URL)
let videoWriter = try AVAssetWriter(outputURL: mp4URL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: pixelWidth,
    AVVideoHeightKey: pixelHeight,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 10_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: Int(fps),
    ],
])
input.expectsMediaDataInRealTime = true
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: pixelWidth,
    kCVPixelBufferHeightKey as String: pixelHeight,
])
videoWriter.add(input)
videoWriter.startWriting()
videoWriter.startSession(atSourceTime: .zero)

let frameCount = Int((preRoll + tourLength) * fps)
let gifStep = Int(fps / gifFPS)
try? FileManager.default.removeItem(at: gifURL)
let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frameCount / gifStep + 1, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let gifFrame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFPS,
                                                kCGImagePropertyGIFUnclampedDelayTime: 1 / gifFPS]] as CFDictionary

let arrow = NSCursor.arrow
let videoFrame = (context: makeContext(width: pixelWidth, height: pixelHeight, scale: scale), backdrop: makeBackdrop(calm: false))
let gifFrameImage = (context: makeContext(width: pixelWidth, height: pixelHeight, scale: scale), backdrop: makeBackdrop(calm: true))
let firstFrame = tourStart - preRoll

/// Draws the backdrop, MusicNotch's windows and the pointer at `time` (seconds from the tour's start).
func compose(_ target: (context: CGContext, backdrop: CGImage), capture frame: CGImage?, time: Double) -> CGImage? {
    let context = target.context
    let bounds = CGRect(origin: .zero, size: canvas)
    for image in [target.backdrop, frame].compactMap({ $0 }) {
        context.saveGState()
        context.translateBy(x: 0, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
    let (point, pressed) = pointer(at: time)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    let size = arrow.image.size.applying(CGAffineTransform(scaleX: pressed ? 0.85 : 1, y: pressed ? 0.85 : 1))
    let hotSpot = CGPoint(x: arrow.hotSpot.x * size.width / arrow.image.size.width,
                          y: arrow.hotSpot.y * size.height / arrow.image.size.height)
    arrow.image.draw(in: CGRect(x: point.x - hotSpot.x, y: point.y - hotSpot.y, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

for index in 0..<frameCount {
    let time = Double(index) / fps
    // Keep pace with the app, a frame behind so the capture has caught up.
    while CACurrentMediaTime() < firstFrame + time + 1 / fps { usleep(1000) }

    let captured = capture.latest
    guard let composed = compose(videoFrame, capture: captured, time: time - preRoll) else { continue }
    if let debug = ProcessInfo.processInfo.environment["MUSICNOTCH_VIDEO_DEBUG"], index % 60 == 0 {
        let tourTime = Int((time - preRoll).rounded())
        if let raw = capture.latest {
            try? NSBitmapImageRep(cgImage: raw).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(debug)/raw-\(tourTime).png"))
        } else {
            print("no captured frame at \(tourTime) s")
        }
    }

    while !input.isReadyForMoreMediaData { usleep(500) }
    var buffer: CVPixelBuffer?
    if let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
       let buffer {
        CVPixelBufferLockBaseAddress(buffer, [])
        let target = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: pixelWidth, height: pixelHeight,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        target?.draw(composed, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
    }

    if index % gifStep == 0, let still = compose(gifFrameImage, capture: captured, time: time - preRoll) {
        CGImageDestinationAddImage(gif, still, gifFrame)
    }
}

input.markAsFinished()
await videoWriter.finishWriting()
CGImageDestinationFinalize(gif)
try? await stream.stopCapture()
process.terminate()
process.waitUntilExit()
try? FileManager.default.removeItem(at: clockFile)

for url in [mp4URL, gifURL] {
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("Wrote docs/\(url.lastPathComponent) (\(bytes / 1024) KB)")
}
