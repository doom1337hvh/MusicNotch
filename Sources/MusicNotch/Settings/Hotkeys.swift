import AppKit
import Carbon.HIToolbox
import Observation

/// What a global keyboard shortcut does.
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case toggleNotch
    case playPause
    case nextTrack
    case previousTrack

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggleNotch: "Open or close the notch"
        case .playPause: "Play or pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        }
    }

    fileprivate var hotKeyID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)! + 1)
    }
}

/// A key with modifiers, as recorded in Settings.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (`cmdKey`, `optionKey`, ...).
    var modifiers: UInt32
    /// The key as shown, e.g. "M" or "Space".
    var keyName: String

    /// Nil unless the key is held with ⌘, ⌥ or ⌃, or is a function key: on its own, a
    /// letter would stop typing it anywhere.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let keyCode = Int(event.keyCode)
        guard Self.functionKeys[keyCode] != nil || !flags.intersection([.command, .option, .control]).isEmpty
        else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers
        keyName = Self.functionKeys[keyCode] ?? Self.specialKeys[keyCode]
            ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
    }

    /// Like "⌃⌥M", in the order the menus use.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

/// Registers the keyboard shortcuts with macOS. Carbon hotkeys work in every app without
/// any permission, and cost nothing until pressed. With no shortcuts set, nothing is registered.
@Observable @MainActor
final class HotkeyCenter {
    /// Shortcuts macOS wouldn't register, usually because another app already uses them.
    private(set) var unavailable: Set<HotkeyAction> = []
    /// Off while a shortcut is being recorded, so pressing an existing one records it
    /// instead of running it.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { apply() } }
    }

    @ObservationIgnored var onAction: ((HotkeyAction) -> Void)?
    @ObservationIgnored private var hotkeys: [HotkeyAction: Hotkey] = [:]
    @ObservationIgnored private var registered: [EventHotKeyRef] = []
    @ObservationIgnored private var handler: EventHandlerRef?

    /// "MNch"
    private static let signature: OSType = 0x4D4E_6368

    func register(_ hotkeys: [HotkeyAction: Hotkey]) {
        self.hotkeys = hotkeys
        apply()
    }

    private func apply() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        guard !isSuspended else { return }
        if !hotkeys.isEmpty { installHandler() }
        var failed = Set<HotkeyAction>()
        for (action, hotkey) in hotkeys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered.append(ref)
            } else {
                failed.insert(action)
            }
        }
        if failed != unavailable { unavailable = failed }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { center.fire(id: id.id) }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func fire(id: UInt32) {
        guard let action = HotkeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
        onAction?(action)
    }
}

/// Records a shortcut in Settings: click a field, then press the keys. Escape cancels;
/// Delete clears the shortcut.
@Observable @MainActor
final class ShortcutRecorder {
    private(set) var recording: HotkeyAction?
    /// Why the last keys pressed weren't taken.
    private(set) var hint: String?

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let hotkeys: HotkeyCenter
    @ObservationIgnored private var monitor: Any?

    init(prefs: Preferences, hotkeys: HotkeyCenter) {
        self.prefs = prefs
        self.hotkeys = hotkeys
    }

    func start(_ action: HotkeyAction) {
        stop()
        recording = action
        hint = nil
        hotkeys.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        hotkeys.isSuspended = false
    }

    func clear(_ action: HotkeyAction) {
        prefs.hotkeys[action] = nil
    }

    /// Returns whether the key press was used, so it doesn't also reach the window.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action = recording else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty && Int(event.keyCode) == kVK_Escape {
            stop()
            return true
        }
        if flags.isEmpty && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
            prefs.hotkeys[action] = nil
            stop()
            return true
        }
        guard let hotkey = Hotkey(event: event) else {
            hint = "Hold ⌘, ⌥ or ⌃ with the key, or use a function key."
            NSSound.beep()
            return true
        }
        // One shortcut, one action.
        for (other, existing) in prefs.hotkeys where other != action
            && existing.keyCode == hotkey.keyCode && existing.modifiers == hotkey.modifiers {
            prefs.hotkeys[other] = nil
        }
        prefs.hotkeys[action] = hotkey
        hint = nil
        stop()
        return true
    }
}
