import CoreGraphics
import Foundation

/// The README's clips, recorded by scripts/make-video.swift. Launched with `-demo <scene>`,
/// MusicNotch shows made-up tracks instead of what's playing and acts out the scene's
/// `steps` with its real views and animations. It doesn't start the media adapter, change any
/// settings, or send anything to the real players.
enum DemoScene: String {
    /// The README's main video: hover, pause, search, a new track.
    case tour
    case closed
    case minimal
    case compact
    case full
    case sources
    case search
    case newTrack = "new-track"
    case settings

    /// The scene asked for on the command line, if any. (`-demo tour` lands in UserDefaults'
    /// argument domain, which is never saved.)
    static let current = UserDefaults.standard.string(forKey: "demo").flatMap(DemoScene.init(rawValue:))

    /// Shuffle on, repeat off, so both button states show.
    static let modes = PlaybackModes(shuffle: true, repeatMode: .off)

    static let tracks: [(title: String, artist: String, duration: TimeInterval, elapsed: TimeInterval, art: Int)] = [
        ("Neon Tides", "Lumen Drive", 222, 81, 1),
        ("Glass Gardens", "Aurora Bay", 198, 40, 3),
        ("Midnight Static", "The Low Orbit", 241, 95, 2),
    ]

    static let searchResults = [
        SearchResult(id: "1", title: "Neon Tides", artist: "Lumen Drive"),
        SearchResult(id: "2", title: "Neon Skyline", artist: "The Low Orbit"),
        SearchResult(id: "3", title: "Under Neon Rain", artist: "Aurora Bay"),
    ]

    /// The playing app: Music where search shows results in the notch, Spotify elsewhere.
    var app: String { self == .tour || self == .search ? "com.apple.Music" : "com.spotify.client" }
    var firstTrack: Int { self == .tour || self == .search ? 1 : 0 }

    /// What's playing: `track` of `tracks` at `elapsed` seconds in. The sources scene adds a
    /// paused video in Chrome and a paused song in Music; Settings has nothing playing.
    func update(track: Int, playing: Bool, elapsed: TimeInterval) -> SessionsUpdate {
        guard self != .settings else { return SessionsUpdate(sessions: [], electedBundleID: nil) }
        let main = Self.session(app, track: track, playing: playing, elapsed: elapsed)
        guard self == .sources else { return SessionsUpdate(sessions: [main], electedBundleID: main.id) }
        return SessionsUpdate(sessions: [
            main,
            Self.session("com.google.Chrome", track: 2, playing: false, elapsed: Self.tracks[2].elapsed),
            Self.session("com.apple.Music", track: 1, playing: false, elapsed: Self.tracks[1].elapsed),
        ], electedBundleID: main.id)
    }

    /// The scene, in seconds from its start. scripts/make-video.swift draws the pointer to
    /// match, so keep the two in step.
    var steps: [(time: Double, step: DemoStep)] {
        switch self {
        case .tour:
            [(1.4, .open(.full)), (3.0, .playing(false)), (4.6, .playing(true)), (6.2, .startSearch)]
                + Self.typing("neon", from: 6.7)
                + [(7.8, .search(text: "neon", results: Self.searchResults)),
                   // Choosing "Neon Tides" closes the notch; the new track then peeks out by itself.
                   (9.2, .closeSearch), (9.6, .track(0))]
        case .closed:
            [(1.6, .playing(false)), (3.4, .playing(true))]
        case .minimal:
            [(1.2, .open(.minimal)), (2.5, .track(2)), (4.2, .collapse)]
        case .compact:
            [(1.2, .open(.compact)), (2.8, .playing(false)), (4.2, .playing(true)), (5.6, .collapse)]
        case .full:
            [(1.2, .open(.full))]
                + Self.scrubbing(from: 0.38, to: 0.72, start: 2.8, end: 3.8)
                + [(3.9, .seek(0.72)),
                   (5.0, .modes(PlaybackModes(shuffle: false, repeatMode: .off))),
                   (5.9, .modes(PlaybackModes(shuffle: false, repeatMode: .all))),
                   (7.4, .collapse)]
        case .sources:
            [(1.2, .open(.full)), (3.0, .select("com.apple.Music")), (4.6, .select("com.google.Chrome")),
             (6.2, .select("com.spotify.client")), (7.6, .collapse)]
        case .search:
            [(1.2, .open(.full)), (2.4, .startSearch)]
                + Self.typing("neon", from: 2.9)
                + [(4.0, .search(text: "neon", results: Self.searchResults)), (5.2, .closeSearch), (5.6, .track(0))]
        case .newTrack:
            [(1.0, .track(2))]
        case .settings:
            [(1.4, .settingsTab(2)), (2.8, .settingsTab(3)), (4.2, .settingsTab(4)), (5.6, .settingsTab(5))]
        }
    }

    /// One letter every 0.2 s.
    private static func typing(_ text: String, from start: Double) -> [(time: Double, step: DemoStep)] {
        text.indices.enumerated().map { offset, index in
            (start + 0.2 * Double(offset), .search(text: String(text[...index]), results: nil))
        }
    }

    /// Drags the progress bar from one fraction to another, 30 times a second.
    private static func scrubbing(from: Double, to: Double, start: Double, end: Double) -> [(time: Double, step: DemoStep)] {
        stride(from: start, through: end, by: 1.0 / 30).map { time in
            let linear = (time - start) / (end - start)
            let eased = linear * linear * (3 - 2 * linear)
            return (time, .scrub(from + (to - from) * eased))
        }
    }

    private static func session(_ bundleID: String, track: Int, playing: Bool, elapsed: TimeInterval) -> MediaSession {
        let track = tracks[track]
        return MediaSession(id: bundleID, snapshot: NowPlayingSnapshot(
            title: track.title, artist: track.artist, album: nil, bundleID: bundleID, parentBundleID: nil,
            isPlaying: playing, playbackRate: 1, duration: track.duration, elapsed: elapsed, timestamp: Date(),
            artwork: artwork(track.art).map { Artwork(id: -track.art, image: $0) }, canSeek: true))
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

/// One step of a scene (`DemoScene.steps`).
enum DemoStep {
    case open(NotchStyle)
    case collapse
    case playing(Bool)
    /// Switches to one of `DemoScene.tracks`.
    case track(Int)
    /// Shows another app's session, as if its icon were clicked.
    case select(String)
    /// The progress bar dragged to a fraction, and released there.
    case scrub(Double)
    case seek(Double)
    case modes(PlaybackModes)
    case startSearch
    case search(text: String, results: [SearchResult]?)
    /// As if a result was chosen: the search closes, and the notch with it.
    case closeSearch
    case settingsTab(Int)
}
