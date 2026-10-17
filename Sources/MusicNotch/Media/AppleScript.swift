import Foundation

/// Runs AppleScripts for apps that can be scripted: Spotify's and Music's own volume,
/// shuffle and repeat. macOS asks once per app ("MusicNotch wants to control Spotify").
@MainActor
final class AppleScriptRunner {
    private var running: [Process] = []
    /// Apps a script has reached before. macOS has already asked about those (and been told
    /// yes), so scripting them again can't bring up a permission prompt.
    private var reachedApps = Set(UserDefaults.standard.stringArray(forKey: AppleScriptRunner.reachedAppsKey) ?? [])
    private static let reachedAppsKey = "scriptedApps"

    /// Runs `script`, which talks to the app `bundleID`; `completion` gets its output, or
    /// nil if it failed.
    func run(_ script: String, app bundleID: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let data = (finished.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            let output = finished.terminationStatus == 0
                ? data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.running.removeAll { $0 === finished }
                    if output != nil { self?.noteReached(bundleID) }
                    completion(output)
                }
            }
        }
        do {
            try process.run()
            running.append(process)
        } catch {
            completion(nil)
            return
        }
        // An app that doesn't answer would leave osascript waiting for minutes.
        Task { [weak process] in
            try? await Task.sleep(for: .seconds(3))
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Whether a script has reached the app before, so running another can't make macOS
    /// ask for permission. (macOS's own check, `AEDeterminePermissionToAutomateTarget`,
    /// can block indefinitely, so it isn't used.)
    func hasReached(app bundleID: String) -> Bool {
        reachedApps.contains(bundleID)
    }

    private func noteReached(_ bundleID: String) {
        guard reachedApps.insert(bundleID).inserted else { return }
        UserDefaults.standard.set(Array(reachedApps).sorted(), forKey: Self.reachedAppsKey)
    }
}
