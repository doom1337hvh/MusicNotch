import Foundation
import OSLog

/// Spotify sometimes keeps telling macOS about a song it played earlier while it plays
/// another, so Control Center shows the wrong song too. That report has a telltale shape: the
/// title and artists run together ("Song • Artists"), and no artist, album or artwork. When
/// Spotify's session looks like that, MusicNotch asks Spotify itself what's playing, through
/// AppleScript, and shows its answer instead. Spotify only gives its artwork as a web address,
/// and MusicNotch never goes online, so the artwork stays blank meanwhile.
///
/// Only once Spotify has been scripted before (shuffle, repeat or volume), so that showing
/// what's playing never brings up a permission prompt by itself.
@MainActor
final class SpotifyTrackCheck {
    /// The latest update with Spotify's session corrected, after Spotify answers.
    var onCorrection: ((SessionsUpdate) -> Void)?

    private let scripts: AppleScriptRunner
    private var latest: SessionsUpdate?
    /// What Spotify last said, and the report it was asked about.
    private var answer: (report: Report, track: Track)?
    private var asked: Report?
    private var isAsking = false

    private static let spotify = "com.spotify.client"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicNotch", category: "spotify")

    init(scripts: AppleScriptRunner) {
        self.scripts = scripts
    }

    /// `update`, with Spotify's session corrected if it looks wrong and Spotify has answered.
    /// Asks Spotify when such a session is new.
    func correct(_ update: SessionsUpdate?) -> SessionsUpdate? {
        latest = update
        guard let update,
              let index = update.sessions.firstIndex(where: { Self.looksWrong($0.snapshot) })
        else { return update }
        let report = Report(update.sessions[index].snapshot)
        if report != asked { ask(about: report) }
        return applied(to: update)
    }

    private func applied(to update: SessionsUpdate) -> SessionsUpdate {
        guard let answer,
              let index = update.sessions.firstIndex(where: { Self.looksWrong($0.snapshot) })
        else { return update }
        var update = update
        let reported = update.sessions[index].snapshot
        var snapshot = reported
        snapshot.title = answer.track.title
        snapshot.artist = answer.track.artist
        snapshot.album = answer.track.album
        snapshot.duration = answer.track.duration ?? reported.duration
        // Spotify's position and state go with its answer. A newer report (Spotify paused,
        // say) keeps its own until Spotify answers about that one too.
        if answer.report == Report(reported) {
            snapshot.elapsed = answer.track.position
            snapshot.timestamp = answer.track.answeredAt
            snapshot.isPlaying = answer.track.isPlaying
        }
        update.sessions[index].snapshot = snapshot
        return update
    }

    private func ask(about report: Report) {
        guard scripts.hasReached(app: Self.spotify), !isAsking else { return }
        asked = report
        isAsking = true
        // One value a line: song names can have commas in them.
        scripts.run("""
            tell application id "\(Self.spotify)"
            set t to current track
            return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (duration of t) & linefeed & (player position) & linefeed & (player state as string)
            end tell
            """, app: Self.spotify) { [weak self] output in
            guard let self else { return }
            isAsking = false
            if let track = output.flatMap(Track.init(output:)) {
                let sameSong = report.title.hasPrefix(track.title + " • ")
                Self.logger.debug("asked Spotify about a report that looked wrong; same song: \(sameSong)")
                answer = (report, track)
                if let latest { onCorrection?(applied(to: latest)) }
            }
            // Spotify's session changed again while it was being asked.
            if let latest, let session = latest.sessions.first(where: { Self.looksWrong($0.snapshot) }),
               Report(session.snapshot) != report {
                ask(about: Report(session.snapshot))
            }
        }
    }

    private static func looksWrong(_ snapshot: NowPlayingSnapshot) -> Bool {
        snapshot.bundleID == spotify && snapshot.artist == nil && snapshot.album == nil
            && snapshot.artwork == nil && snapshot.title.contains(" • ")
    }

    /// One report of Spotify's session: a new one comes with each song change, pause or seek.
    private struct Report: Equatable {
        let title: String
        let elapsed: TimeInterval?
        let timestamp: Date?
        let duration: TimeInterval?
        let isPlaying: Bool

        init(_ snapshot: NowPlayingSnapshot) {
            title = snapshot.title
            elapsed = snapshot.elapsed
            timestamp = snapshot.timestamp
            duration = snapshot.duration
            isPlaying = snapshot.isPlaying
        }
    }

    /// What Spotify says is playing.
    private struct Track {
        let title: String
        let artist: String?
        let album: String?
        let duration: TimeInterval?
        let position: TimeInterval
        let isPlaying: Bool
        let answeredAt: Date

        init?(output: String) {
            let lines = output.components(separatedBy: "\n")
            guard lines.count == 6, !lines[0].isEmpty else { return nil }
            // Some regions write decimals with a comma.
            func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
            title = lines[0]
            artist = lines[1].isEmpty ? nil : lines[1]
            album = lines[2].isEmpty ? nil : lines[2]
            duration = number(lines[3]).flatMap { $0 > 0 ? $0 / 1000 : nil }
            position = number(lines[4]) ?? 0
            isPlaying = lines[5] == "playing"
            answeredAt = Date()
        }
    }
}
