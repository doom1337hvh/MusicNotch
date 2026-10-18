import CoreAudio
import Foundation
import OSLog

/// Mutes the Mac's microphone for every app, with the default input device's own mute, so
/// it works for any call app. The app's own mute button doesn't change, but nobody hears you.
///
/// A muted microphone is easy to forget, so MusicNotch unmutes it again once no app is
/// playing sound (the call has ended), and when it quits. It notes when it muted it, so it
/// can unmute it on the next launch if it didn't get the chance.
@MainActor
final class Microphone {
    private(set) var isMuted = false
    /// Whether the microphone in use can be muted by another app.
    private(set) var canMute = false
    var onChange: (() -> Void)?

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var isRunning = false

    private static let mutedByMusicNotchKey = "mutedMicrophone"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicNotch", category: "sound")

    private var mutedByMusicNotch: Bool {
        get { UserDefaults.standard.bool(forKey: Self.mutedByMusicNotchKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.mutedByMusicNotchKey) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            deviceListener = block
        }
        defaultDeviceChanged()
    }

    func stop() {
        guard isRunning else { return }
        restore()
        isRunning = false
        if let deviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
            self.deviceListener = nil
        }
        stopWatchingMute()
        device = AudioDeviceID(kAudioObjectUnknown)
    }

    func toggle() {
        guard canMute else { return }
        setMuted(!isMuted)
        mutedByMusicNotch = isMuted
    }

    /// Unmutes the microphone if MusicNotch muted it.
    func restore() {
        guard mutedByMusicNotch else { return }
        mutedByMusicNotch = false
        if isMuted { setMuted(false) }
    }

    private func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { Self.logger.error("Couldn't \(muted ? "mute" : "unmute") the microphone: \(status)") }
        read()
    }

    /// A new microphone (say, a headset plugged in) takes over: put the old one back first.
    private func defaultDeviceChanged() {
        if device != AudioDeviceID(kAudioObjectUnknown) { restore() }
        stopWatchingMute()
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var newDevice = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &newDevice)
        device = newDevice
        // Left muted by a MusicNotch that didn't get to unmute it.
        restore()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read() }
        }
        var muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        if device != AudioDeviceID(kAudioObjectUnknown),
           AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, block) == noErr {
            muteListener = block
        }
        read()
    }

    private func stopWatchingMute() {
        guard let muteListener else { return }
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, muteListener)
        self.muteListener = nil
    }

    private func read() {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        let hasMute = device != AudioDeviceID(kAudioObjectUnknown) && AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let muted = hasMute && AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
        guard hasMute != canMute || muted != isMuted else { return }
        canMute = hasMute
        isMuted = muted
        onChange?()
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
