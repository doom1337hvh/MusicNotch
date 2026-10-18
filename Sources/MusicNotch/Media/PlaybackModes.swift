import AppKit

enum RepeatMode: Equatable {
    case off
    case all
    case one
}

struct PlaybackModes: Equatable {
    var shuffle: Bool
    var repeatMode: RepeatMode
}

/// Shuffle and repeat for Spotify and Music, through AppleScript. Neither app reports them
/// to macOS's media controls, so this is the only way to reach them.
///
/// Reading never makes macOS ask for permission: it only runs once a script has reached
/// the app, i.e. after the first click of its shuffle, repeat or volume button.
///
/// Spotify applies a change a moment after the script that made it returns, and until then
/// still reports the old value. So a change's script works out the new state itself and
/// returns that, and reads shortly after a change are skipped.
///
/// Spotify doesn't let other apps use its repeat-one: its AppleScript only repeats the whole
/// playlist, and its own Repeat menu item and shortcut only work while it's in front. So for
/// Spotify, MusicNotch repeats the song itself: just before it ends, it moves Spotify back to
/// the start, and if Spotify moves on to the next song anyway, it goes back (see `follow`).
/// That takes one timer while a song plays on repeat, and a couple of scripts near its end.
@MainActor
final class AppPlaybackModes {
    private struct Terms {
        let shuffle: String
        let repeating: String
    }

    private static let spotify = "com.spotify.client"
    private static let terms: [String: Terms] = [
        spotify: Terms(shuffle: "shuffling", repeating: "repeating"),
        "com.apple.Music": Terms(shuffle: "shuffle enabled", repeating: "song repeat"),
    ]
    /// How long before a song's end MusicNotch moves Spotify back to its start. Spotify starts
    /// the next song a little before the end of the last.
    private static let repeatLead: TimeInterval = 1.5
    /// How long before a song's end MusicNotch asks Spotify for its exact position: the position
    /// macOS reports can be a second or so behind.
    private static let checkLead: TimeInterval = 6
    private static let spotifyRepeatsSongKey = "spotifyRepeatsSong"

    private let runner: AppleScriptRunner
    /// When MusicNotch last changed each app's modes, by bundle ID.
    private var changedAt: [String: Date] = [:]
    /// Whether MusicNotch repeats the song playing in Spotify. Kept across launches.
    private var spotifyRepeatsSong = UserDefaults.standard.bool(forKey: AppPlaybackModes.spotifyRepeatsSongKey) {
        didSet {
            UserDefaults.standard.set(spotifyRepeatsSong, forKey: Self.spotifyRepeatsSongKey)
            if !spotifyRepeatsSong { restartTask?.cancel() }
        }
    }
    /// Moves Spotify back to the start of the song when it's about to end.
    private var restartTask: Task<Void, Never>?
    /// The Spotify song last followed, and when it was due to end.
    private var followed: (title: String, artist: String?, endsAt: Date?)?
    /// When MusicNotch last skipped a song, or went back to the repeated one.
    private var skippedAt: Date?
    private var wentBackAt: Date?
    /// Spotify's session, for starting to repeat in the middle of a song.
    var spotifySnapshot: (() -> NowPlayingSnapshot?)?

    init(scripts: AppleScriptRunner) {
        runner = scripts
    }

    static func supports(bundleID: String) -> Bool {
        terms[bundleID] != nil
    }

    /// The app's shuffle and repeat. Nil if no script has reached the app yet, or if
    /// MusicNotch changed them a moment ago and the app may still report the old values.
    func read(bundleID: String, completion: @escaping @MainActor @Sendable (PlaybackModes?) -> Void) {
        guard let terms = Self.terms[bundleID] else { return completion(nil) }
        if let changed = changedAt[bundleID], Date().timeIntervalSince(changed) < 2 { return completion(nil) }
        guard runner.hasReached(app: bundleID) else { return completion(nil) }
        runner.run("tell application id \"\(bundleID)\" to get {\(terms.shuffle), \(terms.repeating)}",
                   app: bundleID) { [weak self] output in
            completion(output.flatMap { self?.parse($0, bundleID: bundleID) })
        }
    }

    /// Turns shuffle on or off. `completion` gets the modes the app was set to, or nil if it
    /// couldn't be controlled.
    func toggleShuffle(bundleID: String, completion: @escaping @MainActor @Sendable (PlaybackModes?) -> Void) {
        guard let terms = Self.terms[bundleID] else { return completion(nil) }
        change(bundleID: bundleID, """
            set newShuffle to not (\(terms.shuffle))
            set newRepeat to \(terms.repeating)
            set \(terms.shuffle) to newShuffle
            """, completion: completion)
    }

    /// Sets repeat. `completion` gets the modes the app was set to, or nil if it couldn't be
    /// controlled.
    func setRepeat(_ mode: RepeatMode, bundleID: String,
                   completion: @escaping @MainActor @Sendable (PlaybackModes?) -> Void) {
        guard let terms = Self.terms[bundleID] else { return completion(nil) }
        if bundleID == Self.spotify {
            spotifyRepeatsSong = mode == .one
            if mode == .one {
                // Spotify's own repeat is left as it is; the script just reaches Spotify, so
                // macOS asks the first time, and reports its shuffle.
                change(bundleID: bundleID, """
                    set newShuffle to \(terms.shuffle)
                    set newRepeat to \(terms.repeating)
                    """, completion: completion)
                follow(spotifySnapshot?())
                return
            }
        }
        let value = bundleID == Self.spotify
            ? (mode == .off ? "false" : "true")
            : (mode == .off ? "off" : mode == .all ? "all" : "one")
        change(bundleID: bundleID, """
            set newShuffle to \(terms.shuffle)
            set newRepeat to \(value)
            set \(terms.repeating) to newRepeat
            """, completion: completion)
    }

    /// MusicNotch skipped Spotify to another song, which isn't Spotify moving on by itself.
    func noteSkip() {
        skippedAt = Date()
    }

    /// Spotify's session changed (it started, paused, moved or changed song): while repeating
    /// its song, time the move back to the start, or go back if Spotify moved on by itself.
    func follow(_ snapshot: NowPlayingSnapshot?) {
        let previous = followed
        followed = snapshot.map { snapshot in
            let endsAt = snapshot.isPlaying ? snapshot.duration.flatMap { duration in
                snapshot.elapsed(at: Date()).map { Date().addingTimeInterval((duration - $0) / max(snapshot.playbackRate, 0.1)) }
            } : nil
            return (snapshot.title, snapshot.artist, endsAt)
        }
        restartTask?.cancel()
        restartTask = nil
        guard spotifyRepeatsSong, let snapshot else { return }
        let now = Date()
        // A new song shortly before the repeated one was due to end, that MusicNotch didn't skip
        // to: Spotify moved on by itself (its Automix or crossfade can start the next song early).
        if let previous, previous.title != snapshot.title || previous.artist != snapshot.artist,
           let endsAt = previous.endsAt, now > endsAt.addingTimeInterval(-12),
           skippedAt.map({ now.timeIntervalSince($0) > 3 }) ?? true,
           wentBackAt.map({ now.timeIntervalSince($0) > 5 }) ?? true {
            wentBackAt = now
            followed = previous
            runner.run("tell application id \"\(Self.spotify)\" to previous track", app: Self.spotify) { _ in }
            return
        }
        guard snapshot.isPlaying, let duration = snapshot.duration, duration > Self.checkLead + 2,
              let elapsed = snapshot.elapsed(at: now)
        else { return }
        let untilCheck = (duration - elapsed) / max(snapshot.playbackRate, 0.1) - Self.checkLead
        let title = snapshot.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        restartTask = Task { [weak self] in
            if untilCheck > 0 { try? await Task.sleep(for: .seconds(untilCheck)) }
            guard !Task.isCancelled, let self else { return }
            // Keeps macOS from delaying the timers below (App Nap) for these few seconds.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Repeating a Spotify song")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // Spotify's own position, which is exact, for this song only.
            let output: String? = await withCheckedContinuation { continuation in
                runner.run("""
                    tell application id "\(Self.spotify)"
                    if name of current track is "\(title)" then return {player position, duration of current track}
                    end tell
                    """, app: Self.spotify) { continuation.resume(returning: $0) }
            }
            let parts = (output ?? "").components(separatedBy: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard !Task.isCancelled, parts.count == 2 else { return }
            let remaining = parts[1] / 1000 - parts[0]
            try? await Task.sleep(for: .seconds(max(0, remaining - Self.repeatLead)))
            guard !Task.isCancelled else { return }
            runner.run("""
                tell application id "\(Self.spotify)"
                if name of current track is "\(title)" then set player position to 0
                end tell
                """, app: Self.spotify) { _ in }
        }
    }

    /// Runs `body`, which sets `newShuffle` and `newRepeat` and applies them, and reports them.
    private func change(bundleID: String, _ body: String,
                        completion: @escaping @MainActor @Sendable (PlaybackModes?) -> Void) {
        changedAt[bundleID] = Date()
        let script = "tell application id \"\(bundleID)\"\n\(body)\nreturn {newShuffle, newRepeat}\nend tell"
        runner.run(script, app: bundleID) { [weak self] output in
            completion(output.flatMap { self?.parse($0, bundleID: bundleID) })
        }
    }

    /// osascript prints the list as "true, false" (Spotify) or "false, all" (Music).
    private func parse(_ output: String, bundleID: String) -> PlaybackModes? {
        let parts = output.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let repeatMode: RepeatMode
        if bundleID == Self.spotify && spotifyRepeatsSong {
            repeatMode = .one
        } else {
            switch parts[1] {
            case "true", "all": repeatMode = .all
            case "one": repeatMode = .one
            default: repeatMode = .off
            }
        }
        return PlaybackModes(shuffle: parts[0] == "true", repeatMode: repeatMode)
    }
}
