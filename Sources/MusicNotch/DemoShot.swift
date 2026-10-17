import CoreGraphics
import Foundation

/// The README screenshots, made by scripts/make-screenshots.swift. Launched with
/// `-demo <shot>`, MusicNotch shows made-up tracks instead of what's playing and opens the
/// notch in that shot's state. It doesn't start the media adapter or change any settings.
enum DemoShot: String {
    case closed
    case minimal
    case compact
    case full
    case sources
    case newTrack = "new-track"
    case search
    case settings
    /// The README video (scripts/make-video.swift): a scripted tour, see `tourSteps`.
    case tour

    /// The shot asked for on the command line, if any. (`-demo full` lands in UserDefaults'
    /// argument domain, which is never saved.)
    static let current = UserDefaults.standard.string(forKey: "demo").flatMap(DemoShot.init(rawValue:))

    /// The tour, in seconds from its start. scripts/make-video.swift moves the drawn pointer
    /// to match, so keep the two in step.
    static let tourSteps: [(time: Double, step: DemoStep)] = [
        (1.4, .open(.full)),
        (3.0, .playing(false)),
        (4.6, .playing(true)),
        (6.2, .startSearch),
        (6.7, .search(text: "n", results: nil)),
        (6.9, .search(text: "ne", results: nil)),
        (7.1, .search(text: "neo", results: nil)),
        (7.3, .search(text: "neon", results: nil)),
        (7.8, .search(text: "neon", results: searchResults)),
        // Choosing "Neon Tides" closes the notch; the new track then peeks out by itself.
        (9.2, .closeSearch),
        (9.6, .track(1)),
    ]

    /// The tour's tracks, all from Music so its search shows results in the notch.
    static func tourUpdate(track: Int, playing: Bool) -> SessionsUpdate {
        let music = track == 1
            ? session("com.apple.Music", "Neon Tides", "Lumen Drive", playing: playing, duration: 222, elapsed: 0, art: 1)
            : session("com.apple.Music", "Glass Gardens", "Aurora Bay", playing: playing, duration: 198, elapsed: 40, art: 3)
        return SessionsUpdate(sessions: [music], electedBundleID: music.id)
    }

    /// Shuffle on, repeat off, so both button states show.
    static let modes = PlaybackModes(shuffle: true, repeatMode: .off)

    /// Made-up Music library results, for the search shot.
    static let searchText = "neon"
    static let searchResults = [
        SearchResult(id: "1", title: "Neon Tides", artist: "Lumen Drive"),
        SearchResult(id: "2", title: "Neon Skyline", artist: "The Low Orbit"),
        SearchResult(id: "3", title: "Under Neon Rain", artist: "Aurora Bay"),
    ]

    var update: SessionsUpdate {
        if self == .tour { return Self.tourUpdate(track: 0, playing: true) }
        if self == .search {
            let music = Self.session("com.apple.Music", "Glass Gardens", "Aurora Bay", playing: true,
                                     duration: 198, elapsed: 40, art: 3)
            return SessionsUpdate(sessions: [music], electedBundleID: music.id)
        }
        let spotify = Self.session("com.spotify.client", "Neon Tides", "Lumen Drive", playing: true,
                                   duration: 222, elapsed: 81, art: 1)
        guard self == .sources else {
            return SessionsUpdate(sessions: [spotify], electedBundleID: spotify.id)
        }
        return SessionsUpdate(sessions: [
            spotify,
            Self.session("com.google.Chrome", "Midnight Static (Live Session)", "The Low Orbit", playing: false,
                         duration: 1490, elapsed: 312, art: 2),
            Self.session("com.apple.Music", "Glass Gardens", "Aurora Bay", playing: false,
                         duration: 198, elapsed: 40, art: 3),
        ], electedBundleID: spotify.id)
    }

    private static func session(_ bundleID: String, _ title: String, _ artist: String, playing: Bool,
                                duration: TimeInterval, elapsed: TimeInterval, art: Int) -> MediaSession {
        MediaSession(id: bundleID, snapshot: NowPlayingSnapshot(
            title: title, artist: artist, album: nil, bundleID: bundleID, parentBundleID: nil,
            isPlaying: playing, playbackRate: 1, duration: duration, elapsed: elapsed, timestamp: Date(),
            artwork: artwork(art).map { Artwork(id: -art, image: $0) }, canSeek: true))
    }

    /// Simple made-up album covers.
    private static func artwork(_ style: Int) -> CGImage? {
        let size = 256
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        func gradient(_ colors: [CGColor]) -> CGGradient {
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
        }
        // Core Graphics' y axis points up.
        switch style {
        case 1:
            // A synthwave sunset: striped sun over a dark horizon.
            context.drawLinearGradient(gradient([color(0xFF6A88), color(0x7B2FF7), color(0x1B0B3A)]),
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 256), options: [])
            context.saveGState()
            context.addEllipse(in: CGRect(x: 58, y: 70, width: 140, height: 140))
            context.clip()
            context.drawLinearGradient(gradient([color(0xFF3D77), color(0xFFD86B)]),
                                       start: CGPoint(x: 0, y: 70), end: CGPoint(x: 0, y: 210), options: [])
            context.restoreGState()
            context.setFillColor(color(0x2A0E52))
            for (y, height) in [(84, 5), (100, 6), (117, 7), (135, 8)] {
                context.fill(CGRect(x: 50, y: y, width: 156, height: height))
            }
            context.setFillColor(color(0x12062A))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 74))
            context.setStrokeColor(color(0xFF4FD8, 0.55))
            context.setLineWidth(2)
            for x in stride(from: -256, through: 512, by: 48) {
                context.move(to: CGPoint(x: 128, y: 74))
                context.addLine(to: CGPoint(x: x, y: 0))
            }
            for y in [8, 22, 40, 60] {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: 256, y: y))
            }
            context.strokePath()
        case 2:
            // A crescent moon in a starry sky.
            context.drawLinearGradient(gradient([color(0x0F2027), color(0x203A43), color(0x2C5364)]),
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 256, y: 256), options: [])
            context.setFillColor(color(0xFFFFFF, 0.8))
            for (x, y, r) in [(40, 200, 2.5), (80, 230, 1.5), (210, 60, 2), (190, 220, 1.5), (60, 70, 1.5),
                              (230, 150, 2.5), (120, 40, 1.5), (30, 130, 2)] as [(Double, Double, Double)] {
                context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            context.setFillColor(color(0xF6E7B4))
            context.fillEllipse(in: CGRect(x: 78, y: 78, width: 104, height: 104))
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 108, y: 98, width: 96, height: 96))
            context.setBlendMode(.normal)
            context.saveGState()
            context.setBlendMode(.destinationOver)
            context.drawLinearGradient(gradient([color(0x0F2027), color(0x203A43), color(0x2C5364)]),
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 256, y: 256), options: [])
            context.restoreGState()
        default:
            // Overlapping glassy circles.
            context.drawLinearGradient(gradient([color(0x43E97B), color(0x38F9D7), color(0x4FACFE)]),
                                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 256, y: 256), options: [])
            for (x, y, r, alpha) in [(90, 150, 70, 0.35), (170, 110, 60, 0.3), (130, 70, 45, 0.25)]
                as [(Double, Double, Double, Double)] {
                context.setFillColor(color(0xFFFFFF, alpha))
                context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }
        return context.makeImage()
    }
}

/// One step of the tour (`DemoShot.tourSteps`).
enum DemoStep {
    case open(NotchStyle)
    case playing(Bool)
    case startSearch
    case search(text: String, results: [SearchResult]?)
    /// As if a result was chosen: the search closes, and the notch with it.
    case closeSearch
    /// Switches to one of `DemoShot.tourUpdate`'s tracks.
    case track(Int)
}
