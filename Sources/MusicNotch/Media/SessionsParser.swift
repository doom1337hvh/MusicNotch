import Foundation
import ImageIO

/// Turns the adapter's "sessions" stream (Adapter/MusicNotchSessions.m) into updates.
///
/// Each line is `{"type":"sessions","elected":…,"sessions":[…]}`, listing every app with a
/// media session. A session's artwork data is only sent when its artwork changes, so the
/// decoded image is kept per session and reused while its artwork identifier stays the same.
///
/// Only ever used from one serial queue (a pipe's readability handler).
final class SessionsParser: @unchecked Sendable {
    private var buffer = Data()
    private var artworkBySession: [String: (identifier: String, artwork: Artwork)] = [:]
    private var artworkCount = 0
    private let artworkPixelSize: Int

    init(artworkPixelSize: Int = 128) {
        self.artworkPixelSize = artworkPixelSize
    }

    /// Appends output from the adapter. Returns the latest complete update, if any.
    func consume(_ chunk: Data) -> SessionsUpdate? {
        buffer.append(chunk)
        var latest: SessionsUpdate?
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            if let update = parse(buffer[lineStart..<newline]) { latest = update }
            lineStart = buffer.index(after: newline)
        }
        buffer.removeSubrange(buffer.startIndex..<lineStart)
        return latest
    }

    private func parse(_ line: Data) -> SessionsUpdate? {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["type"] as? String == "sessions",
              let list = message["sessions"] as? [[String: Any]]
        else { return nil }

        var sessions: [MediaSession] = []
        for fields in list {
            guard let key = fields["sessionKey"] as? String,
                  let title = Self.string(fields["title"]),
                  let bundleID = Self.string(fields["bundleIdentifier"])
            else { continue }
            let artworkID = fields["artworkIdentifier"] as? String ?? ""
            if let base64 = fields["artworkData"] as? String, let artwork = decodeArtwork(base64) {
                artworkBySession[key] = (artworkID, artwork)
            }
            let artwork = artworkBySession[key].flatMap { $0.identifier == artworkID ? $0.artwork : nil }
            let snapshot = NowPlayingSnapshot(
                title: title,
                artist: Self.string(fields["artist"]),
                album: Self.string(fields["album"]),
                bundleID: bundleID,
                parentBundleID: Self.string(fields["parentApplicationBundleIdentifier"]),
                isPlaying: fields["playing"] as? Bool ?? false,
                playbackRate: (fields["playbackRate"] as? NSNumber)?.doubleValue ?? 1,
                duration: Self.seconds(fields["durationMicros"]).flatMap { $0 > 0 ? $0 : nil },
                elapsed: Self.seconds(fields["elapsedTimeMicros"]),
                timestamp: Self.seconds(fields["timestampEpochMicros"]).map(Date.init(timeIntervalSince1970:)),
                artwork: artwork,
                canSeek: fields["canSeek"] as? Bool ?? false
            )
            sessions.append(MediaSession(id: key, snapshot: snapshot))
        }
        let ids = Set(sessions.map(\.id))
        artworkBySession = artworkBySession.filter { ids.contains($0.key) }
        return SessionsUpdate(sessions: sessions, electedBundleID: Self.string(message["elected"]))
    }

    private func decodeArtwork(_ base64: String) -> Artwork? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        artworkCount += 1
        return Artwork(id: artworkCount, image: image)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        (value as? NSNumber).map { $0.doubleValue / 1_000_000 }
    }
}
