import Foundation

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
@MainActor
final class AppPlaybackModes {
    private struct Terms {
        let shuffle: String
        let repeating: String
        /// Spotify's repeat is on or off; Music's also repeats one song.
        let hasRepeatOne: Bool
    }

    private static let terms: [String: Terms] = [
        "com.spotify.client": Terms(shuffle: "shuffling", repeating: "repeating", hasRepeatOne: false),
        "com.apple.Music": Terms(shuffle: "shuffle enabled", repeating: "song repeat", hasRepeatOne: true),
    ]

    private let runner: AppleScriptRunner
    /// When MusicNotch last changed each app's modes, by bundle ID.
    private var changedAt: [String: Date] = [:]

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
                   app: bundleID) { output in
            completion(output.flatMap(Self.parse))
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

    /// Steps repeat to its next mode: off, all, one (Music only), off. `completion` gets the
    /// modes the app was set to, or nil if it couldn't be controlled.
    func cycleRepeat(bundleID: String, completion: @escaping @MainActor @Sendable (PlaybackModes?) -> Void) {
        guard let terms = Self.terms[bundleID] else { return completion(nil) }
        let next = terms.hasRepeatOne
            ? """
              set newRepeat to \(terms.repeating)
              if newRepeat is off then
                  set newRepeat to all
              else if newRepeat is all then
                  set newRepeat to one
              else
                  set newRepeat to off
              end if
              """
            : "set newRepeat to not (\(terms.repeating))"
        change(bundleID: bundleID, """
            set newShuffle to \(terms.shuffle)
            \(next)
            set \(terms.repeating) to newRepeat
            """, completion: completion)
    }

    /// The mode the repeat button moves to from `mode`, to show before the app answers.
    static func nextRepeat(after mode: RepeatMode, bundleID: String) -> RepeatMode {
        switch mode {
        case .off: .all
        case .all: terms[bundleID]?.hasRepeatOne == true ? .one : .off
        case .one: .off
        }
    }

    /// Runs `body`, which sets `newShuffle` and `newRepeat` and applies them, and reports them.
    private func change(bundleID: String, _ body: String,
                        completion: @escaping @MainActor @Sendable (PlaybackModes?) -> Void) {
        changedAt[bundleID] = Date()
        let script = "tell application id \"\(bundleID)\"\n\(body)\nreturn {newShuffle, newRepeat}\nend tell"
        runner.run(script, app: bundleID) { output in
            completion(output.flatMap(Self.parse))
        }
    }

    /// osascript prints the list as "true, false" (Spotify) or "false, all" (Music).
    private static func parse(_ output: String) -> PlaybackModes? {
        let parts = output.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let repeatMode: RepeatMode
        switch parts[1] {
        case "true", "all": repeatMode = .all
        case "one": repeatMode = .one
        default: repeatMode = .off
        }
        return PlaybackModes(shuffle: parts[0] == "true", repeatMode: repeatMode)
    }
}
