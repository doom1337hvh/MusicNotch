import CoreGraphics
import Foundation
import Observation

/// Album art, already downsampled for display. Compared by identity so views
/// don't redraw when an unchanged image is passed along with other updates.
struct Artwork: @unchecked Sendable, Equatable {
    let id: Int
    let image: CGImage
    /// The artwork's most vivid colour, made bright enough to stand out on black; nil for
    /// artwork that's black and white. Worked out once, when the artwork arrives.
    let tint: CGColor?

    init(id: Int, image: CGImage) {
        self.id = id
        self.image = image
        tint = Self.vividColor(in: image)
    }

    static func == (lhs: Artwork, rhs: Artwork) -> Bool { lhs.id == rhs.id }

    /// Groups a small copy's pixels by hue, weighted by how vivid each is, and takes the
    /// average colour of the strongest group.
    private static func vividColor(in image: CGImage) -> CGColor? {
        let side = 24
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let groups = 24
        var weights = [Double](repeating: 0, count: groups)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: groups)
        for index in 0..<(side * side) {
            let r = Double(pixels[index * 4]) / 255, g = Double(pixels[index * 4 + 1]) / 255
            let b = Double(pixels[index * 4 + 2]) / 255
            let (hue, saturation, brightness) = hsb(r, g, b)
            let weight = saturation * saturation * brightness
            guard brightness > 0.15, weight > 0.02 else { continue }
            let group = min(Int(hue * Double(groups)), groups - 1)
            weights[group] += weight
            sums[group] = (sums[group].r + r * weight, sums[group].g + g * weight, sums[group].b + b * weight)
        }
        // Neighbouring hues count together, so a gradient isn't split between groups.
        let smoothed = weights.indices.map { weights[$0] + 0.5 * (weights[($0 + groups - 1) % groups] + weights[($0 + 1) % groups]) }
        guard let best = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }),
              smoothed[best] > Double(side * side) * 0.02, weights[best] > 0
        else { return nil }
        let average = (sums[best].r / weights[best], sums[best].g / weights[best], sums[best].b / weights[best])
        let (hue, saturation, brightness) = hsb(average.0, average.1, average.2)
        let (r, g, b) = rgb(hue, min(max(saturation, 0.45), 0.85), max(brightness, 0.9))
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        guard range > 0 else { return (0, 0, high) }
        var hue: Double
        if high == r { hue = (g - b) / range } else if high == g { hue = 2 + (b - r) / range } else { hue = 4 + (r - g) / range }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, range / high, high)
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> (Double, Double, Double) {
        let sector = hue * 6, chroma = brightness * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - chroma
        let (r, g, b): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}

struct NowPlayingSnapshot: Sendable, Equatable {
    var title: String
    var artist: String?
    var album: String?
    var bundleID: String
    var parentBundleID: String?
    var isPlaying: Bool
    var playbackRate: Double
    var duration: TimeInterval?
    /// Playback position at `timestamp`.
    var elapsed: TimeInterval?
    var timestamp: Date?
    var artwork: Artwork?
    /// Whether the app accepts a jump to a position, i.e. the progress bar can be dragged.
    var canSeek = false

    /// The bundle ID of the app to bring forward, e.g. the browser for web audio.
    var sourceAppBundleID: String { parentBundleID ?? bundleID }

    func elapsed(at date: Date) -> TimeInterval? {
        guard var position = elapsed else { return nil }
        if isPlaying, let timestamp {
            position += date.timeIntervalSince(timestamp) * (playbackRate > 0 ? playbackRate : 1)
        }
        if let duration { position = min(position, duration) }
        return max(0, position)
    }
}

/// One app's media session, as reported by the adapter's "sessions" stream.
struct MediaSession: Sendable, Equatable, Identifiable {
    /// The app's bundle ID, made unique if one app has several sessions.
    let id: String
    var snapshot: NowPlayingSnapshot
}

/// Every app's media session, plus the one macOS treats as "now playing". Media commands
/// only ever reach that app.
struct SessionsUpdate: Sendable, Equatable {
    var sessions: [MediaSession]
    var electedBundleID: String?
}

/// What the notch shows. Fed by `AdapterProcess`.
///
/// Several apps can have media at once (say Spotify playing and a paused YouTube video),
/// while macOS only reports the one that most recently started playing, even after it's
/// paused. So this picks the most active session itself, and remembers the others so the
/// panel can offer them.
@Observable @MainActor
final class NowPlaying {
    private(set) var sessions: [MediaSession] = []
    private(set) var electedBundleID: String?
    /// The session the user picked from the source icons, if any.
    private(set) var pinnedSessionID: String?
    private(set) var displayedSessionID: String?
    /// The displayed session's state.
    private(set) var snapshot: NowPlayingSnapshot?

    /// Called when media appears (`true`) or has been gone for the grace period (`false`).
    @ObservationIgnored var onPresenceChange: ((Bool) -> Void)?
    /// Called when the displayed track changes, not when media first appears.
    @ObservationIgnored var onTrackChange: (() -> Void)?
    /// The displayed session and track, to notice track changes.
    @ObservationIgnored private var lastTrack: [String?]?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// When each session started playing, to prefer the one started most recently.
    @ObservationIgnored private var playingSince: [String: Date] = [:]
    @ObservationIgnored private var wasVisible = false
    /// When MusicNotch last changed each app's volume, by bundle ID.
    @ObservationIgnored private var volumeChangedAt: [String: Date] = [:]

    var displayedSession: MediaSession? {
        sessions.first { $0.id == displayedSessionID }
    }

    /// Whether the displayed session is macOS's "now playing" app, the only one media
    /// commands reach.
    var isDisplayedElected: Bool {
        guard let snapshot, let electedBundleID else { return false }
        return snapshot.bundleID == electedBundleID
    }

    /// False if this macOS can't send commands to apps other than its "now playing" one.
    var canTargetApps = true

    /// Whether the buttons can reach the displayed app.
    var canControlDisplayed: Bool {
        snapshot != nil && (isDisplayedElected || canTargetApps)
    }

    /// Spotify re-publishes its now playing info with the position reset to 0 whenever its
    /// volume changes, so updates for the same track shortly after a volume change keep the
    /// position already known.
    func noteVolumeChange(bundleID: String) {
        volumeChangedAt[bundleID] = Date()
    }

    func receive(_ update: SessionsUpdate?) {
        var update = update ?? SessionsUpdate(sessions: [], electedBundleID: nil)
        let now = Date()
        for index in update.sessions.indices {
            let incoming = update.sessions[index].snapshot
            guard let changedAt = volumeChangedAt[incoming.bundleID], now.timeIntervalSince(changedAt) < 2,
                  let known = sessions.first(where: { $0.id == update.sessions[index].id })?.snapshot,
                  known.title == incoming.title, known.artist == incoming.artist,
                  known.isPlaying == incoming.isPlaying
            else { continue }
            update.sessions[index].snapshot.elapsed = known.elapsed
            update.sessions[index].snapshot.timestamp = known.timestamp
        }
        var startedPlaying = Set<String>()
        for session in update.sessions {
            if session.snapshot.isPlaying {
                if playingSince[session.id] == nil {
                    playingSince[session.id] = now
                    startedPlaying.insert(session.id)
                }
            } else {
                playingSince[session.id] = nil
            }
        }
        let ids = Set(update.sessions.map(\.id))
        playingSince = playingSince.filter { ids.contains($0.key) }

        if let pinned = pinnedSessionID {
            // A pick lasts until that session ends or something else starts playing.
            if !ids.contains(pinned) || !startedPlaying.subtracting([pinned]).isEmpty {
                pinnedSessionID = nil
            }
        }
        if update.sessions != sessions { sessions = update.sessions }
        if update.electedBundleID != electedBundleID { electedBundleID = update.electedBundleID }
        select()

        if sessions.isEmpty {
            scheduleHide()
        } else {
            hideTask?.cancel()
            hideTask = nil
            if snapshot != nil && !wasVisible {
                wasVisible = true
                onPresenceChange?(true)
            }
        }
    }

    /// Shows a session picked from the source icons.
    func pin(_ sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        pinnedSessionID = sessionID
        select()
    }

    /// Flips play/pause right away; the adapter's next update confirms it.
    func togglePlayPauseOptimistically() {
        guard var updated = snapshot else { return }
        let now = Date()
        updated.elapsed = updated.elapsed(at: now)
        updated.timestamp = now
        updated.isPlaying.toggle()
        snapshot = updated
    }

    /// Moves the progress bar right away; the adapter's next update confirms it.
    func seekOptimistically(to position: TimeInterval) {
        guard var updated = snapshot else { return }
        updated.elapsed = position
        updated.timestamp = Date()
        snapshot = updated
    }

    /// The pick if there is one; otherwise whatever is playing, preferring macOS's choice
    /// and then the most recently started; otherwise stay on the current session (so
    /// pausing it doesn't jump to another app); otherwise macOS's choice.
    private func select() {
        let playing = sessions.filter(\.snapshot.isPlaying)
        let chosen: MediaSession? =
            sessions.first { $0.id == pinnedSessionID }
            ?? playing.first { $0.snapshot.bundleID == electedBundleID }
            ?? playing.max { (playingSince[$0.id] ?? .distantPast) < (playingSince[$1.id] ?? .distantPast) }
            ?? sessions.first { $0.id == displayedSessionID }
            ?? sessions.first { $0.snapshot.bundleID == electedBundleID }
            ?? sessions.first
        if chosen?.id != displayedSessionID { displayedSessionID = chosen?.id }
        if let chosen, chosen.snapshot != snapshot { snapshot = chosen.snapshot }
        if let chosen {
            let track = [chosen.id, chosen.snapshot.title, chosen.snapshot.artist]
            if let lastTrack, lastTrack != track { onTrackChange?() }
            lastTrack = track
        }
    }

    /// Players briefly report nothing between tracks, so wait before hiding.
    private func scheduleHide() {
        guard snapshot != nil, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            self.snapshot = nil
            self.displayedSessionID = nil
            self.lastTrack = nil
            self.wasVisible = false
            self.onPresenceChange?(false)
        }
    }
}
