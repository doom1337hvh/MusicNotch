import AppKit
import CoreAudio
import OSLog

/// An app playing sound, or using the microphone, that doesn't report to macOS's Now Playing,
/// like a call or a game.
struct SoundApp: Equatable, Sendable {
    let bundleID: String
    let name: String
    let url: URL
    /// Using the microphone: most likely in a call.
    var usesMicrophone = false
}

/// Finds the apps playing sound or using the microphone that don't report to macOS's Now
/// Playing (calls, games), from Core Audio's list of processes using audio, on macOS 14.2 and
/// later. Core Audio says when a process starts or stops using audio, so this does nothing in
/// between.
///
/// Only regular apps (with a Dock icon) count, and only after a couple of seconds, so alerts
/// and notification sounds don't flash up in the notch. An app using the microphone is
/// treated as being in a call. Helper processes, like a
/// browser's or Teams' audio helpers and Safari's WebKit, count as the app they belong to.
///
/// It also deafens an app: a Core Audio tap set to mute holds the app's sound back from the
/// speakers for as long as the tap exists. Nothing is ever read from it, so nothing is
/// recorded and no audio runs through MusicNotch. Creating one needs the System Audio
/// Recording permission, which macOS asks for the first time.
@MainActor
final class SoundApps {
    /// The apps playing sound, in the order they started.
    private(set) var apps: [SoundApp] = []
    var onChange: (([SoundApp]) -> Void)?
    /// The apps deafened, by bundle ID.
    private(set) var deafened: Set<String> = []
    var onDeafenChange: ((Set<String>) -> Void)?

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    /// Core Audio's process objects, with the app each belongs to (nil: not a regular app).
    private var processes: [AudioObjectID: SoundApp?] = [:]
    /// Processes playing sound, and ones using the microphone.
    private var playingProcesses: Set<AudioObjectID> = []
    private var recordingProcesses: Set<AudioObjectID> = []
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    /// Apps waiting out the delay before they appear or disappear.
    private var settling: [String: Task<Void, Never>] = [:]
    /// The muting tap of each deafened app, and the processes it covers.
    private var taps: [String: (tap: AudioObjectID, processes: Set<AudioObjectID>)] = [:]

    private static let appearDelay: Duration = .seconds(2)
    /// Calls and games pause their sound now and then; don't drop them for that.
    private static let disappearDelay: Duration = .seconds(3)
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicNotch", category: "sound")

    func start() {
        guard Self.isSupported, listListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processListChanged() }
        }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr
        else { return Self.logger.error("Couldn't watch Core Audio's processes") }
        listListener = block
        processListChanged()
    }

    func stop() {
        guard let listListener else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
        self.listListener = nil
        processListeners.keys.forEach(stopListening)
        processes = [:]
        playingProcesses = []
        recordingProcesses = []
        settling.values.forEach { $0.cancel() }
        settling = [:]
        for bundleID in deafened { untap(bundleID) }
        setDeafened([])
        setApps([])
    }

    func toggleDeafen(_ bundleID: String) {
        if deafened.contains(bundleID) {
            untap(bundleID)
            setDeafened(deafened.subtracting([bundleID]))
        } else if tap(bundleID) {
            setDeafened(deafened.union([bundleID]))
        }
    }

    // MARK: Following the processes

    private func processListChanged() {
        let current = Set(Self.processObjects())
        for gone in processes.keys where !current.contains(gone) {
            stopListening(gone)
            processes[gone] = nil
            playingProcesses.remove(gone)
            recordingProcesses.remove(gone)
        }
        for object in current where !processes.keys.contains(object) {
            let app = Self.app(forProcess: object)
            // Kept even when nil (not a regular app), so it isn't looked into again.
            processes.updateValue(app, forKey: object)
            guard app != nil else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.audioChanged(object) }
            }
            for selector in Self.watched {
                var address = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
            }
            processListeners[object] = block
            readAudio(object)
        }
        // A deafened app that started or ended a helper needs its tap to cover the new set.
        for (bundleID, existing) in taps where processObjects(of: bundleID) != existing.processes {
            untap(bundleID)
            if !tap(bundleID) { setDeafened(deafened.subtracting([bundleID])) }
        }
        update()
    }

    /// Playing sound, and using the microphone.
    private static let watched = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput]

    private func stopListening(_ object: AudioObjectID) {
        guard let block = processListeners.removeValue(forKey: object) else { return }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    private func audioChanged(_ object: AudioObjectID) {
        readAudio(object)
        update()
    }

    private func readAudio(_ object: AudioObjectID) {
        if Self.isRunning(object, kAudioProcessPropertyIsRunningOutput) {
            playingProcesses.insert(object)
        } else {
            playingProcesses.remove(object)
        }
        if Self.isRunning(object, kAudioProcessPropertyIsRunningInput) {
            recordingProcesses.insert(object)
        } else {
            recordingProcesses.remove(object)
        }
    }

    /// Starts the delay for apps that started or stopped using audio, and cancels it for ones
    /// that went back to how they were. An app already shown that starts or stops using the
    /// microphone changes straight away.
    private func update() {
        let recording = appIDs(recordingProcesses)
        let refreshed = apps.map { app in
            var app = app
            app.usesMicrophone = recording.contains(app.bundleID)
            return app
        }
        setApps(refreshed)
        let playing = playingAppIDs
        let shown = Set(apps.map(\.bundleID))
        for bundleID in playing.symmetricDifference(shown) where settling[bundleID] == nil {
            let delay = playing.contains(bundleID) ? Self.appearDelay : Self.disappearDelay
            settling[bundleID] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.settle(bundleID)
            }
        }
        for (bundleID, task) in settling where playing.contains(bundleID) == shown.contains(bundleID) {
            task.cancel()
            settling[bundleID] = nil
        }
    }

    private func settle(_ bundleID: String) {
        settling[bundleID] = nil
        let isPlaying = playingAppIDs.contains(bundleID)
        if isPlaying, !apps.contains(where: { $0.bundleID == bundleID }),
           var app = processes.values.lazy.compactMap({ $0 }).first(where: { $0.bundleID == bundleID }) {
            app.usesMicrophone = appIDs(recordingProcesses).contains(bundleID)
            Self.logger.info("using audio: \(bundleID, privacy: .public), microphone \(app.usesMicrophone, privacy: .public)")
            setApps(apps + [app])
        } else if !isPlaying, apps.contains(where: { $0.bundleID == bundleID }) {
            Self.logger.info("stopped playing sound: \(bundleID, privacy: .public)")
            // Deafening ends with the sound it was for.
            if deafened.contains(bundleID) {
                untap(bundleID)
                setDeafened(deafened.subtracting([bundleID]))
            }
            setApps(apps.filter { $0.bundleID != bundleID })
        }
    }

    /// Apps playing sound or using the microphone.
    private var playingAppIDs: Set<String> {
        appIDs(playingProcesses.union(recordingProcesses))
    }

    private func appIDs(_ objects: Set<AudioObjectID>) -> Set<String> {
        Set(objects.compactMap { processes[$0] ?? nil }.map(\.bundleID))
    }

    private func setApps(_ new: [SoundApp]) {
        guard new != apps else { return }
        apps = new
        onChange?(new)
    }

    private func setDeafened(_ new: Set<String>) {
        guard new != deafened else { return }
        deafened = new
        onDeafenChange?(new)
    }

    // MARK: Deafening

    private func processObjects(of bundleID: String) -> Set<AudioObjectID> {
        Set(processes.filter { $0.value?.bundleID == bundleID }.keys)
    }

    /// Mutes every process of the app with a tap; false if it couldn't, say because System
    /// Audio Recording isn't allowed.
    private func tap(_ bundleID: String) -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let objects = processObjects(of: bundleID)
        guard !objects.isEmpty else { return false }
        let description = CATapDescription(stereoMixdownOfProcesses: Array(objects))
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "MusicNotch deafen"
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            Self.logger.error("Couldn't deafen \(bundleID, privacy: .public): \(status)")
            return false
        }
        taps[bundleID] = (tap, objects)
        return true
    }

    private func untap(_ bundleID: String) {
        guard #available(macOS 14.2, *), let tap = taps.removeValue(forKey: bundleID) else { return }
        AudioHardwareDestroyProcessTap(tap.tap)
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                  as type: T.Type) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func isRunning(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        (value(object, selector, as: UInt32.self) ?? 0) != 0
    }

    // MARK: Which app a process belongs to

    /// The regular app a process belongs to: itself, or the app responsible for it (a
    /// helper's or an XPC service's), found by the outermost .app around its executable.
    private static func app(forProcess object: AudioObjectID) -> SoundApp? {
        guard let pid = value(object, kAudioProcessPropertyPID, as: pid_t.self), pid > 0 else { return nil }
        let owner = responsiblePID(pid) ?? pid
        guard owner != getpid(), pid != getpid(),
              let path = executablePath(owner).flatMap(appBundlePath) ?? executablePath(pid).flatMap(appBundlePath)
        else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                  .contains(where: { $0.activationPolicy == .regular })
        else { return nil }
        let name = FileManager.default.displayName(atPath: path)
        return SoundApp(bundleID: bundleID, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, url: url)
    }

    /// The outermost app bundle in a path, e.g. Teams itself for one of its helpers.
    private static func appBundlePath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<path.index(before: range.upperBound)])
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    /// macOS's record of which app launched a helper or service; private, so looked up at
    /// run time. Without it, helpers still match by their own path.
    private static let responsibleFunction = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                   "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsiblePID.self) }

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let owner = responsibleFunction(pid)
        return owner > 0 ? owner : nil
    }
}
