import Foundation

/// Reads and sets the volume of apps that have their own: Spotify and Music, through
/// AppleScript. macOS asks once per app ("MusicNotch wants to control Spotify"). Browser
/// players keep their volume inside the web page, out of reach.
@MainActor
final class AppVolume {
    private static let supported: Set<String> = ["com.spotify.client", "com.apple.Music"]

    private let scripts: AppleScriptRunner
    private var isSetting = false
    private var pending: (bundleID: String, level: Double)?

    init(scripts: AppleScriptRunner) {
        self.scripts = scripts
    }

    static func supports(bundleID: String) -> Bool {
        supported.contains(bundleID)
    }

    /// Reads the app's volume, 0...1, or nil if it can't (for example, if access was denied).
    func read(bundleID: String, completion: @escaping @MainActor @Sendable (Double?) -> Void) {
        guard Self.supports(bundleID: bundleID) else {
            completion(nil)
            return
        }
        scripts.run("tell application id \"\(bundleID)\" to get sound volume", app: bundleID) { output in
            completion(output.flatMap(Double.init).map { min(max($0 / 100, 0), 1) })
        }
    }

    /// Sets the app's volume, 0...1. While one change is on its way, only the latest of the
    /// following ones is kept, so dragging the slider doesn't queue up dozens of scripts.
    func set(_ level: Double, bundleID: String) {
        guard Self.supports(bundleID: bundleID) else { return }
        pending = (bundleID, level)
        sendPending()
    }

    private func sendPending() {
        guard !isSetting, let (bundleID, level) = pending else { return }
        pending = nil
        isSetting = true
        let percent = Int((level * 100).rounded())
        scripts.run("tell application id \"\(bundleID)\" to set sound volume to \(percent)", app: bundleID) { [weak self] _ in
            self?.isSetting = false
            self?.sendPending()
        }
    }
}
