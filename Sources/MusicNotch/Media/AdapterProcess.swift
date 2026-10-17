import Foundation
import Observation

struct AdapterOptions: Equatable {
    var includeArtwork: Bool
    var debounceMilliseconds: Int
}

/// Streams every app's media session and sends playback commands.
///
/// Since macOS 15.4, MediaRemote only answers Apple-signed processes, so the adapter's
/// framework is loaded into `/usr/bin/perl`, which is. The stream is MusicNotch's own
/// "sessions" command (Adapter/MusicNotchSessions.m, built into the framework). Commands for
/// macOS's "now playing" app use mediaremote-adapter's `send`; commands for any other app use
/// MusicNotch's own `send` (Adapter/MusicNotchSend.m). See https://github.com/ungive/mediaremote-adapter
@Observable @MainActor
final class AdapterProcess {
    enum Command: Equatable {
        case togglePlayPause
        case nextTrack
        case previousTrack
        /// Jumps to a position, in seconds.
        case seek(TimeInterval)

        /// mediaremote-adapter's arguments, for macOS's "now playing" app.
        var adapterArguments: [String] {
            switch self {
            case .togglePlayPause: ["send", "2"]
            case .nextTrack: ["send", "4"]
            case .previousTrack: ["send", "5"]
            case .seek(let seconds): ["seek", String(Int(max(0, seconds) * 1_000_000))]
            }
        }

        /// The command for MusicNotch's own `send`, for any other app.
        var targetedArgument: String {
            switch self {
            case .togglePlayPause: "2"
            case .nextTrack: "4"
            case .previousTrack: "5"
            case .seek(let seconds): "seek=" + String(format: "%.3f", max(0, seconds))
            }
        }
    }

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)
    }

    private(set) var status: Status = .stopped
    /// Whether the adapter has reported any media since launch, i.e. it is known to work.
    private(set) var hasSeenMedia = false

    @ObservationIgnored var onUpdate: ((SessionsUpdate?) -> Void)?
    /// Called if this macOS can't send commands to a specific app.
    @ObservationIgnored var onTargetingUnavailable: (() -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var options: AdapterOptions?
    /// Bumped whenever a stream process is replaced, so late callbacks from the old one are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var quickFailures = 0
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var commandProcesses: [Process] = []
    @ObservationIgnored private var didClearOrphans = false
    /// Commands for a specific app briefly override macOS's "now playing" app, so they run
    /// one at a time.
    @ObservationIgnored private var targetedCommands: [(Command, NowPlayingSnapshot)] = []
    @ObservationIgnored private var isSendingTargetedCommand = false

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private static let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    private static let helperScript = Bundle.main.url(forResource: "musicnotch-adapter", withExtension: "pl")
    private static let framework = Bundle.main.privateFrameworksURL?
        .appendingPathComponent("MediaRemoteAdapter.framework")

    /// Starts streaming, or restarts the stream if the options changed.
    func start(options: AdapterOptions) {
        guard options != self.options || process == nil else { return }
        self.options = options
        quickFailures = 0
        launch()
    }

    func stop() {
        restartTask?.cancel()
        generation += 1
        process?.terminate()
        process = nil
        status = .stopped
    }

    /// Sends `command` to macOS's "now playing" app, or to `target`'s app if given.
    func send(_ command: Command, to target: NowPlayingSnapshot? = nil) {
        if let target {
            targetedCommands.append((command, target))
            sendNextTargetedCommand()
            return
        }
        guard let script = Self.script, let framework = Self.framework else { return }
        runCommand([script.path, framework.path] + command.adapterArguments)
    }

    private func sendNextTargetedCommand() {
        guard !isSendingTargetedCommand, !targetedCommands.isEmpty,
              let script = Self.helperScript, let framework = Self.framework
        else { return }
        let (command, target) = targetedCommands.removeFirst()
        clearLeftoverOverride()
        var arguments = [script.path, framework.path, "send", command.targetedArgument, target.bundleID]
        if let parent = target.parentBundleID { arguments.append(parent) }
        isSendingTargetedCommand = true
        runCommand(arguments) { [weak self] exitStatus in
            guard let self else { return }
            isSendingTargetedCommand = false
            // 1: this macOS lacks the override functions.
            if exitStatus == 1 { onTargetingUnavailable?() }
            sendNextTargetedCommand()
        }
    }

    private func runCommand(_ arguments: [String], completion: (@MainActor @Sendable (Int32) -> Void)? = nil) {
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["MUSICNOTCH_OVERRIDE_MARKER": Self.overrideMarker.path]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let exitStatus = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.commandProcesses.removeAll { $0 === finished }
                    completion?(exitStatus)
                }
            }
        }
        do {
            try process.run()
            commandProcesses.append(process)
        } catch {
            NSLog("MusicNotch: couldn't send command: \(error)")
            completion?(-1)
        }
    }

    /// Where MusicNotch's `send` records that it has macOS's "now playing" app overridden.
    private static let overrideMarker: URL = {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MusicNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("media-override.pid")
    }()

    /// If a `send` was killed while it had the "now playing" app overridden, the override
    /// would stay on system-wide; switch it off.
    private func clearLeftoverOverride() {
        guard let contents = try? String(contentsOf: Self.overrideMarker, encoding: .utf8) else { return }
        if let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
            return  // Still running; it clears the override itself.
        }
        if let script = Self.helperScript, let framework = Self.framework {
            let process = Process()
            process.executableURL = Self.perl
            process.arguments = [script.path, framework.path, "clear-override"]
            process.environment = ProcessInfo.processInfo.environment
                .merging(["MUSICNOTCH_OVERRIDE_MARKER": Self.overrideMarker.path]) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: Self.overrideMarker)
    }

    private func launch() {
        restartTask?.cancel()
        generation += 1
        process?.terminate()
        process = nil

        guard let options, let script = Self.helperScript, let framework = Self.framework,
              FileManager.default.fileExists(atPath: framework.path)
        else {
            status = .failed("The media adapter is missing from the app bundle. Rebuild with scripts/build.sh.")
            return
        }
        if !didClearOrphans {
            didClearOrphans = true
            Self.clearQuarantine()
            terminateOrphans(using: framework)
            clearLeftoverOverride()
        }

        var arguments = [script.path, framework.path, "sessions"]
        if options.debounceMilliseconds > 0 {
            arguments.append("--debounce=\(options.debounceMilliseconds)")
        }
        if !options.includeArtwork {
            arguments.append("--no-artwork")
        }

        let process = Process()
        process.executableURL = Self.perl
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let generation = self.generation
        let parser = SessionsParser()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let update = parser.consume(chunk) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    if !update.sessions.isEmpty { self.hasSeenMedia = true }
                    self.onUpdate?(update)
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.streamExited(generation: generation, code: code) }
            }
        }

        do {
            try process.run()
            self.process = process
            startedAt = Date()
            status = .running
        } catch {
            status = .failed("Couldn't start the media adapter: \(error.localizedDescription)")
        }
    }

    private func streamExited(generation: Int, code: Int32) {
        guard generation == self.generation else { return }
        process = nil
        onUpdate?(nil)

        let exitedQuickly = Date().timeIntervalSince(startedAt) < 10
        quickFailures = (code != 0 && exitedQuickly) ? quickFailures + 1 : 0
        // The adapter's README asks consumers not to loop on fatal errors.
        guard quickFailures < 3 else {
            status = .failed("The media adapter keeps exiting (code \(code)). It may not support this version of macOS.")
            return
        }
        status = .stopped
        let delay = Double(1 + quickFailures * 2)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    /// A downloaded copy has the browser's quarantine flag on every file. MusicNotch itself
    /// only runs once the user has approved it, but Gatekeeper would still stop
    /// `/usr/bin/perl` from loading the adapter framework inside it, so the flag comes off
    /// the bundle's own files.
    private static func clearQuarantine() {
        // Built locally, nothing is flagged; leave the files alone.
        guard let adapter = framework?.appendingPathComponent("Versions/A/MediaRemoteAdapter"),
              getxattr(adapter.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        else { return }
        let bundle = Bundle.main.bundleURL
        removexattr(bundle.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let files = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files {
            removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// A stream left behind by a crashed copy of this app keeps running until its
    /// next write fails, so end any that use this app's framework.
    private func terminateOrphans(using framework: URL) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", NSRegularExpression.escapedPattern(for: framework.path) + " (stream|sessions)"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()
    }
}
