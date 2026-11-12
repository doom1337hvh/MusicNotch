import AppKit
import AppShell
import Observation
import SwiftUI

/// Whether MusicNotch may see the Dock's swipe gestures (Input Monitoring), for "Hide while swiping".
@Observable @MainActor
final class SwipePermission {
    private(set) var isAllowed = SwipeMonitor.hasPermission

    func refresh() {
        isAllowed = SwipeMonitor.hasPermission
    }

    func request() {
        SwipeMonitor.requestPermission()
        refresh()
    }

    func openSystemSettings() {
        SwipeMonitor.openPermissionSettings()
    }
}

/// MusicNotch's Settings window: AppShell's, with a tab per topic between General and About.
@MainActor
final class SettingsWindowController {
    var onBecameKey: (() -> Void)?
    private let window: SettingsWindow

    init(prefs: Preferences, adapter: AdapterProcess, hotkeys: HotkeyCenter, menuBar: MenuBar) {
        let recorder = ShortcutRecorder(prefs: prefs, hotkeys: hotkeys)
        let swipePermission = SwipePermission()
        window = SettingsWindow {
            [
                .general(menuBar: menuBar,
                         iconHiddenNote: "To get back here, open MusicNotch again or right-click the notch.") {
                    GeneralSettings(prefs: prefs)
                },
                SettingsTab("Notch", symbol: "rectangle.topthird.inset.filled") { NotchSettings(prefs: prefs) },
                SettingsTab("Appearance", symbol: "paintpalette") { AppearanceSettings(prefs: prefs) },
                SettingsTab("Animations", symbol: "sparkles") {
                    AnimationSettings(prefs: prefs, swipePermission: swipePermission)
                },
                SettingsTab("Shortcuts", symbol: "keyboard") {
                    ShortcutSettings(prefs: prefs, hotkeys: hotkeys, recorder: recorder)
                },
                SettingsTab("Performance", symbol: "leaf") { PerformanceSettings(prefs: prefs) },
                .about(thirdParty: [
                    Licence("Uses mediaremote-adapter by Jonas van den Berg, under the BSD 3-Clause License.",
                            file: "mediaremote-adapter-LICENSE"),
                ]) {
                    AdapterStatus(adapter: adapter)
                },
            ]
        }
        window.onResignedKey = { recorder.stop() }
        window.onClose = { recorder.stop() }
        window.onBecameKey = { [weak self] in
            swipePermission.refresh()
            self?.onBecameKey?()
        }
    }

    func show() {
        window.show()
    }
}

/// General's own section, below Launch at login and the menu bar icon.
private struct GeneralSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Section("Where it appears") {
            Toggle(isOn: $prefs.showOnExternalDisplays) {
                Text("Show on displays without a notch")
                Text("Adds a small pill at the top center of external displays.")
            }
            Picker(selection: $prefs.hideInFullScreen) {
                ForEach(FullScreenHiding.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Hide in full screen")
                Text("\"When the playing app is\" hides it while a full-screen app plays, which includes a full-screen browser playing anything.")
            }
        }
    }
}

private struct NotchSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Section("When closed") {
            Toggle(isOn: $prefs.showBesideNotch) {
                Text("Show artwork and bars beside the notch")
                Text("When off, nothing shows until you hover over the notch, and the equalizer uses no power.")
            }
            Toggle(isOn: $prefs.showTrackPeek) {
                Text("Show new tracks")
                Text("When the song changes, the notch briefly opens to show it.")
            }
            Toggle(isOn: $prefs.tucksWhenIdle) {
                Text("Tuck away when nothing plays")
                Text("After a while with no sound, the artwork and bars slide in behind the camera; hover over it to open the notch. They come back as soon as something plays.")
            }
            if prefs.tucksWhenIdle {
                Picker("After", selection: $prefs.idleMinutes) {
                    ForEach(Preferences.idleMinuteChoices, id: \.self) { minutes in
                        Text(minutes == 60 ? "1 hour" : minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
            }
            Toggle(isOn: SoundApps.isSupported ? $prefs.showSoundApps : .constant(false)) {
                Text("Show other apps playing sound")
                Text(SoundApps.isSupported
                     ? "Calls and games, with buttons to mute your microphone and to deafen the app. An app using the microphone comes first, even over music."
                     : "Needs macOS 14.2 or later.")
            }
            .disabled(!SoundApps.isSupported)
        }

        Section("Opening") {
            Picker(selection: $prefs.notchStyle) {
                ForEach(NotchStyle.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Style")
                Text("Minimal widens the notch with skip buttons. Compact and Full open a panel.")
            }
            Picker(selection: $prefs.openTrigger) {
                ForEach(NotchOpenTrigger.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Open on")
                Text("Click keeps it from opening as you reach for menu bar items nearby.")
            }
            Toggle(isOn: $prefs.openFromCameraOnly) {
                Text("Only open from the camera")
                Text("The closed notch's sides let the pointer through to the menu bar.")
            }
        }
    }
}

private struct AppearanceSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Section {
            Picker(selection: prefs.isLowResource ? .constant(.black) : $prefs.theme) {
                ForEach(NotchTheme.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Theme")
                Text("Glass lets the desktop show through, with black fading out around the camera.")
            }
            .disabled(prefs.isLowResource)
            Picker(selection: $prefs.accentColour) {
                ForEach(AccentColour.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Colour")
                Text(prefs.accentColour == .artwork && !prefs.effectiveArtwork
                     ? "Needs the album artwork, so for now it's white."
                     : "For the equalizer, progress bar and volume slider.")
            }
            if prefs.accentColour == .solid {
                ColorPicker("Solid colour", selection: $prefs.solidColour, supportsOpacity: false)
            }
        } header: {
            Text("Look")
        } footer: {
            if prefs.isLowResource {
                LowResourceNote(text: "Low-resource mode turns glass off.")
            }
        }

        Section {
            Toggle(isOn: effective(\.showArtwork)) {
                Text("Album artwork")
                Text("When off, artwork isn't loaded at all.")
            }
            .disabled(prefs.isLowResource)
            Toggle(isOn: effective(\.showProgressBar)) {
                Text("Progress bar")
                Text("Drag it to skip through the song. Updates once a second, only while open.")
            }
            .disabled(prefs.isLowResource)
            Toggle(isOn: $prefs.showShuffleRepeat) {
                Text("Shuffle and repeat buttons")
                Text("For Spotify and Music; repeat repeats the song. The first click asks to let MusicNotch control the app.")
            }
            Toggle(isOn: $prefs.showSearch) {
                Text("Search button")
                Text("Searches your Music library right in the notch, or sends a search to Spotify, YouTube or SoundCloud.")
            }
            Toggle("Click the artwork to open the playing app", isOn: $prefs.clickArtworkOpensApp)
        } header: {
            Text("In the open notch")
        } footer: {
            if prefs.isLowResource {
                LowResourceNote(text: "Low-resource mode turns off the artwork and progress bar.")
            }
        }
    }

    /// While low-resource mode is on, a switch shows as off and can't be changed.
    private func effective(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        prefs.isLowResource ? .constant(false) : $prefs[dynamicMember: keyPath]
    }
}

private struct AnimationSettings: View {
    @Bindable var prefs: Preferences
    let swipePermission: SwipePermission

    var body: some View {
        Section {
            Picker(selection: prefs.isLowResource ? .constant(.instant) : $prefs.openAnimation) {
                ForEach(OpenAnimation.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Open animation")
                Text("How the notch opens and closes.")
            }
            .disabled(prefs.isLowResource)
        }

        Section {
            Picker(selection: prefs.isLowResource ? .constant(.none) : $prefs.spaceSwitchAnimation) {
                ForEach(SpaceSwitchAnimation.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Appear on the new desktop")
                Text("Fade fades the whole notch in. Slide brings the artwork and bars in from the side the new desktop came from. Expand grows them out from behind the camera.")
            }
            .disabled(prefs.isLowResource)
            Toggle(isOn: hideDuringSwipes) {
                Text("Hide while swiping")
                Text("Hides the notch as soon as a swipe starts, instead of letting it leave with the old desktop. Needs Input Monitoring, used only for the Dock's swipe gesture.")
            }
            if prefs.hideDuringSwipes && !swipePermission.isAllowed {
                LabeledContent {
                    Button("Open System Settings") { swipePermission.openSystemSettings() }
                } label: {
                    Text("\(Image(systemName: "exclamationmark.triangle.fill")) Needs Input Monitoring")
                        .foregroundStyle(.orange)
                    Text("In Input Monitoring, remove MusicNotch if it's listed, then add it again with + and turn it on.")
                }
            }
        } header: {
            Text("Switching desktops")
        } footer: {
            if prefs.isLowResource {
                LowResourceNote(text: "Low-resource mode turns the animations off.")
            }
        }
    }

    /// Turning it on asks for Input Monitoring the first time.
    private var hideDuringSwipes: Binding<Bool> {
        Binding {
            prefs.hideDuringSwipes
        } set: { enabled in
            if enabled && !swipePermission.isAllowed { swipePermission.request() }
            prefs.hideDuringSwipes = enabled
        }
    }
}

private struct ShortcutSettings: View {
    @Bindable var prefs: Preferences
    let hotkeys: HotkeyCenter
    let recorder: ShortcutRecorder

    var body: some View {
        Section {
            ForEach(HotkeyAction.allCases) { action in
                LabeledContent(action.label) {
                    ShortcutField(action: action, hotkey: prefs.hotkeys[action],
                                  isUnavailable: hotkeys.unavailable.contains(action), recorder: recorder)
                }
            }
            if let hint = recorder.hint, recorder.recording != nil {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Shortcuts work in any app. Click a field, then press the keys; Delete clears it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PerformanceSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Section {
            Toggle(isOn: $prefs.lowResourceMode) {
                Text("Low-resource mode")
                Text("The lowest power use in one switch: turns off the animations, glass, artwork and progress bar, and batches updates once a second.")
            }
            Toggle(isOn: $prefs.followLowPowerMode) {
                Text("Turn on with Low Power Mode")
                Text("While macOS's Low Power Mode is on, so is low-resource mode.")
            }
            .disabled(prefs.lowResourceMode)
        } footer: {
            if prefs.isLowResourceForLowPowerMode {
                LowResourceNote(text: "Low Power Mode is on, so low-resource mode is too.")
            }
        }

        Section {
            Picker(selection: prefs.isLowResource ? .constant(.never) : $prefs.equalizerAnimation) {
                ForEach(EqualizerAnimation.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Equalizer animation")
                Text("The moving bars are the only thing that uses power continuously. Otherwise they stay still.")
            }
            Picker(selection: prefs.isLowResource ? .constant(.batterySaver) : $prefs.updateBatching) {
                ForEach(UpdateBatching.allCases) { Text($0.label).tag($0) }
            } label: {
                Text("Update batching")
                Text("Groups bursts of track changes into fewer updates.")
            }
        }
        .disabled(prefs.isLowResource)
    }
}

/// The media adapter's state, in About.
private struct AdapterStatus: View {
    let adapter: AdapterProcess

    var body: some View {
        LabeledContent("Media adapter", value: status)
    }

    private var status: String {
        // A demo clip (`DemoScene`) never starts the adapter.
        if DemoScene.current != nil { return "Working" }
        return switch adapter.status {
        case .failed(let message): message
        case .stopped: "Starting…"
        case .running: adapter.hasSeenMedia ? "Working" : "Running, no media seen yet"
        }
    }
}

/// Says why some settings are off while low-resource mode is on.
private struct LowResourceNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "leaf")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shows a shortcut; click it to record a new one.
private struct ShortcutField: View {
    let action: HotkeyAction
    let hotkey: Hotkey?
    let isUnavailable: Bool
    let recorder: ShortcutRecorder

    var body: some View {
        let isRecording = recorder.recording == action
        HStack(spacing: 6) {
            if isUnavailable && !isRecording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Another app already uses this shortcut, so macOS won't give it to MusicNotch.")
            }
            Button {
                if isRecording { recorder.stop() } else { recorder.start(action) }
            } label: {
                Text(isRecording ? "Press keys…" : hotkey?.display ?? "Record Shortcut")
                    .frame(minWidth: 110)
            }
            if hotkey != nil && !isRecording {
                Button {
                    recorder.clear(action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }
}
